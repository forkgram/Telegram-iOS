import Foundation
import MtProtoKit
import SwiftSignalKit

/// Configuration and endpoint selection for the MTProto-over-WebSocket transport.
///
/// Telegram's web client reaches every datacenter through a WebSocket endpoint that
/// terminates the abridged MTProto transport itself (`wss://kws<dc>.web.telegram.org/apiws`).
/// Those endpoints are reachable through the Cloudflare-fronted relay domains that the
/// `Flowseal/tg-ws-proxy` project publishes, which is what makes the transport useful on
/// networks that drop or throttle direct MTProto TCP. This class decides which endpoint a
/// datacenter should be offered, remembers how each one behaved, and hands the result to
/// `MTContext.webSocketAddressesProvider`.
///
/// Only datacenters 1...5 carry these endpoints; the WebSocket option is ignored while an
/// MTProxy or SOCKS proxy is configured, and any number of consecutive failures falls back to
/// plain TCP for a minute (the schemes of a datacenter are rebuilt without the endpoints).
public final class NetworkWebSocketTransport {
    public static let shared = NetworkWebSocketTransport()
    
    public static let settingsChangedNotification = Notification.Name("NetworkWebSocketTransportSettingsChanged")
    public static let endpointsChangedNotification = Notification.Name("NetworkWebSocketTransportEndpointsChanged")
    
    private let queue = Queue(name: "NetworkWebSocketTransport")
    private let defaults = UserDefaults.standard
    
    private let relayDomainsURLs = [
        "https://raw.githubusercontent.com/Flowseal/tg-ws-proxy/main/.github/cfproxy-domains.txt",
        "https://gcore.jsdelivr.net/gh/Flowseal/tg-ws-proxy@main/.github/cfproxy-domains.txt",
        "https://fastly.jsdelivr.net/gh/Flowseal/tg-ws-proxy@main/.github/cfproxy-domains.txt",
        "https://cdn.jsdelivr.net/gh/Flowseal/tg-ws-proxy@main/.github/cfproxy-domains.txt",
        "https://raw.githack.com/Flowseal/tg-ws-proxy/main/.github/cfproxy-domains.txt"
    ]
    // Listed in the same obfuscated form as the published list: `decodeRelayDomain` turns each
    // one into the `<name>.co.uk` host that actually exists.
    private static let fallbackRelayDomains = [
        "virkgj.com", "vmmzovy.com", "mkuosckvso.com", "zaewayzmplad.com", "twdmbzcm.com",
        "awzwsldi.com", "clngqrflngqin.com", "tjacxbqtj.com", "bxaxtxmrw.com", "dmohrsgmohcrwb.com",
        "vwbmtmoi.com", "khgrre.com", "ulihssf.com", "tmhqsdqmfpmk.com", "xwuwoqbm.com",
        "orgcnunpj.com", "zhkuldz.com", "zypoljnslxa.com", "efabnxaowuzs.com", "zaftuzsftqdq.com"
    ]
    private let domainsTTL: TimeInterval = 60 * 60
    private let domainsRetryInterval: TimeInterval = 30 * 60
    private let maxPoolSize = 64
    private let minValidPool = 3
    
    private var enabled: Bool
    private var userDomain: String
    private var pool: [String]
    private var rotation: Int = 0
    
    private var refreshingDomains = false
    private var lastDomainsFailure: Date?
    
    private var hostStrikes: [String: Int] = [:]
    private var hostCooldownUntil: [String: Date] = [:]
    private var consecutiveFailures: Int = 0
    private var suppressedUntil: Date?
    
    private func log(_ text: String) {
        Logger.shared.log("WS", text)
        #if TGBUILD
        NSLog("[ws] %@", text)
        #endif
    }
    
    /// Posted when the set of offered endpoints may have changed: the settings were changed,
    /// the relay pool was refreshed, or the health state moved into or out of suppression.
    /// Owners refresh the affected transport schemes in response.
    private func notifyEndpointsChanged() {
        NotificationCenter.default.post(name: NetworkWebSocketTransport.endpointsChangedNotification, object: self)
    }
    
    private init() {
        self.enabled = self.defaults.bool(forKey: "forkgram.webSocketTransport.enabled")
        self.userDomain = self.defaults.string(forKey: "forkgram.webSocketTransport.domain") ?? ""
        self.pool = NetworkWebSocketTransport.decodePool(cached: self.defaults.string(forKey: "forkgram.webSocketTransport.domainsCache") ?? "", fallback: NetworkWebSocketTransport.fallbackRelayDomains)
    }
    
    public var isEnabled: Bool {
        var value = false
        self.queue.sync {
            value = self.enabled
        }
        return value
    }
    
    public var currentUserDomain: String {
        var value = ""
        self.queue.sync {
            value = self.userDomain
        }
        return value
    }
    
    // MARK: - Settings
    
    public func setEnabled(_ enabled: Bool, domain: String) {
        let domain = NetworkWebSocketTransport.normalizeDomain(domain)
        self.queue.async {
            self.enabled = enabled
            self.userDomain = domain
            self.defaults.set(enabled, forKey: "forkgram.webSocketTransport.enabled")
            self.defaults.set(domain, forKey: "forkgram.webSocketTransport.domain")
            self.resetHealth()
            NotificationCenter.default.post(name: NetworkWebSocketTransport.settingsChangedNotification, object: nil)
            self.notifyEndpointsChanged()
        }
        if enabled && domain.isEmpty {
            self.refreshRelayDomains(force: false)
        }
    }
    
    /// Endpoints for a datacenter. Returns `[]` when the transport is off, suppressed, or the
    /// datacenter has no WebSocket endpoint (anything outside 1...5).
    public func addresses(datacenterId: Int, media: Bool) -> [MTDatacenterAddress] {
        guard datacenterId >= 1 && datacenterId <= 5 else {
            return []
        }
        var result: [MTDatacenterAddress] = []
        self.queue.sync {
            guard self.enabled else {
                return
            }
            if let suppressedUntil = self.suppressedUntil {
                if suppressedUntil > Date() {
                    return
                }
                self.suppressedUntil = nil
            }
            // `MTContext` appends these schemes after the TCP ones, and
            // `chooseTransportSchemeForConnectionToDatacenterId:` keeps the LAST scheme on a
            // failure-timestamp tie. Reversing here makes `endpointsLocked`'s preference order
            // (direct endpoint, then relay pool) the order the transport actually tries.
            result = self.endpointsLocked(datacenterId: datacenterId, media: media).reversed().map { endpoint in
                return MTDatacenterAddress(webSocketIp: endpoint.host, port: 443, path: endpoint.path, preferForMedia: media)
            }
        }
        return result
    }
    
    // MARK: - Health
    
    public func reportSuccess(host: String) {
        self.queue.async {
            guard self.enabled else {
                return
            }
            // The offered endpoint set only changes when suppression is lifted: clearing a
            // strike or cooldown does not add or remove endpoints, and announcing it would make
            // the owner rebuild the datacenter's schemes (and tear down the very connection
            // that just started working) on every successful connection.
            let wasSuppressed = self.suppressedUntil != nil
            self.hostStrikes.removeValue(forKey: host)
            self.hostCooldownUntil.removeValue(forKey: host)
            self.consecutiveFailures = 0
            self.suppressedUntil = nil
            if wasSuppressed {
                self.log("endpoint \(host) works, WebSocket transport unsuppressed")
                self.notifyEndpointsChanged()
            }
        }
    }
    
    public func reportFailure(host: String) {
        self.queue.async {
            guard self.enabled else {
                return
            }
            let strikes = (self.hostStrikes[host] ?? 0) + 1
            self.hostStrikes[host] = strikes
            self.hostCooldownUntil[host] = Date(timeIntervalSinceNow: NetworkWebSocketTransport.escalatedCooldown(strikes: strikes))
            self.consecutiveFailures += 1
            self.log("endpoint \(host) failed (strike \(strikes), cooldown \(Int(NetworkWebSocketTransport.escalatedCooldown(strikes: strikes)))s, consecutive \(self.consecutiveFailures))")
            if self.consecutiveFailures >= 6 {
                self.suppressedUntil = Date(timeIntervalSinceNow: 60.0)
                self.consecutiveFailures = 0
                self.notifyEndpointsChanged()
            }
        }
    }
    
    private func resetHealth() {
        self.hostStrikes.removeAll()
        self.hostCooldownUntil.removeAll()
        self.consecutiveFailures = 0
        self.suppressedUntil = nil
    }
    
    private static func escalatedCooldown(strikes: Int) -> TimeInterval {
        var cooldown = 45.0
        var index = 1
        while index < strikes && cooldown < 300.0 {
            cooldown *= 2.0
            index += 1
        }
        return min(cooldown, 300.0)
    }
    
    // MARK: - Endpoint selection
    
    private struct Endpoint {
        let host: String
        let path: String
    }
    
    private func endpointsLocked(datacenterId: Int, media: Bool) -> [Endpoint] {
        let path = "/apiws"
        // An account's own domain wins unconditionally: it is a deliberate choice, not a
        // candidate to be rotated away from.
        if !self.userDomain.isEmpty {
            return [Endpoint(host: "kws\(datacenterId).\(self.userDomain)", path: path)]
        }
        
        var result: [Endpoint] = []
        func appendIfHealthy(_ host: String) {
            guard !result.contains(where: { $0.host == host }) else {
                return
            }
            if let cooldown = self.hostCooldownUntil[host], cooldown > Date() {
                return
            }
            result.append(Endpoint(host: host, path: path))
        }
        
        appendIfHealthy("kws\(datacenterId)\(media ? "-1" : "").web.telegram.org")
        if media {
            // The `-1` media endpoint is a separate host with its own health; the generic one
            // still carries media traffic when the media endpoint is refused.
            appendIfHealthy("kws\(datacenterId).web.telegram.org")
        }
        
        if !self.pool.isEmpty && result.count < 2 {
            var index = 0
            while index < self.pool.count && result.count < 2 {
                let domain = self.pool[(self.rotation + index) % self.pool.count]
                index += 1
                appendIfHealthy("kws\(datacenterId).\(domain)")
            }
        }
        
        self.rotation += 1
        return result
    }
    
    // MARK: - Relay domain pool
    
    public func refreshRelayDomainsIfNeeded() {
        self.refreshRelayDomains(force: false)
    }
    
    public func refreshRelayDomains(force: Bool) {
        var shouldStart = false
        self.queue.sync {
            if !self.enabled || !self.userDomain.isEmpty {
                return
            }
            let cacheTime = self.defaults.double(forKey: "forkgram.webSocketTransport.domainsCacheTime")
            let haveCache = (self.defaults.string(forKey: "forkgram.webSocketTransport.domainsCache") ?? "").isEmpty == false
            let age = Date().timeIntervalSince1970 - cacheTime
            if !force {
                if haveCache && age < self.domainsTTL {
                    return
                }
                if let lastDomainsFailure = self.lastDomainsFailure, Date().timeIntervalSince(lastDomainsFailure) < self.domainsRetryInterval {
                    return
                }
            }
            if self.refreshingDomains {
                return
            }
            self.refreshingDomains = true
            shouldStart = true
        }
        guard shouldStart else {
            return
        }
        
        let deadline = Date(timeIntervalSinceNow: 20.0)
        self.fetchPool(urlIndex: 0, deadline: deadline, accumulated: nil)
    }
    
    private func fetchPool(urlIndex: Int, deadline: Date, accumulated: [String]?) {
        if urlIndex >= self.relayDomainsURLs.count || Date() > deadline {
            self.finishPoolFetch(parsed: nil)
            return
        }
        let urlString = self.relayDomainsURLs[urlIndex]
        guard let url = URL(string: urlString + "?cb=\(Int(Date().timeIntervalSince1970 * 1000))") else {
            self.fetchPool(urlIndex: urlIndex + 1, deadline: deadline, accumulated: accumulated)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.dataTask(with: request, completionHandler: { [weak self] data, _, _ in
            guard let self = self else {
                return
            }
            if let data = data, data.count <= 64 * 1024, let body = String(data: data, encoding: .utf8) {
                if let parsed = NetworkWebSocketTransport.parseRelayDomains(body) {
                    self.finishPoolFetch(parsed: parsed)
                    return
                }
            }
            self.fetchPool(urlIndex: urlIndex + 1, deadline: deadline, accumulated: accumulated)
        })
        task.resume()
    }
    
    private func finishPoolFetch(parsed: [String]?) {
        self.queue.async {
            self.refreshingDomains = false
            guard let validDomains = parsed, validDomains.count >= self.minValidPool else {
                self.lastDomainsFailure = Date()
                return
            }
            self.lastDomainsFailure = nil
            self.defaults.set(validDomains.joined(separator: "\n"), forKey: "forkgram.webSocketTransport.domainsCache")
            self.defaults.set(Date().timeIntervalSince1970, forKey: "forkgram.webSocketTransport.domainsCacheTime")
            self.pool = NetworkWebSocketTransport.decodePool(cached: validDomains.joined(separator: "\n"), fallback: NetworkWebSocketTransport.fallbackRelayDomains)
            self.notifyEndpointsChanged()
        }
    }
    
    private static func parseRelayDomains(_ body: String) -> [String]? {
        var result: [String] = []
        for rawLine in body.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let decoded = NetworkWebSocketTransport.decodeRelayDomain(line)
            if NetworkWebSocketTransport.isValidRelayDomain(decoded) {
                result.append(line)
            } else if NetworkWebSocketTransport.isValidRelayDomain(line) {
                result.append(line)
            }
            if result.count >= 64 {
                break
            }
        }
        return result.count >= 3 ? result : nil
    }
    
    private static func decodePool(cached: String, fallback: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in cached.split(separator: "\n") {
            let domain = NetworkWebSocketTransport.decodeRelayDomain(String(line))
            if NetworkWebSocketTransport.isValidRelayDomain(domain) && seen.insert(domain).inserted {
                result.append(domain)
            }
        }
        for line in fallback {
            let domain = NetworkWebSocketTransport.decodeRelayDomain(line)
            if NetworkWebSocketTransport.isValidRelayDomain(domain) && seen.insert(domain).inserted {
                result.append(domain)
            }
        }
        return result
    }
    
    /// The published list ships `*.com` names that are Caesar-shifted back to the `*.co.uk`
    /// hosts that actually resolve; a plain domain is returned as written.
    static func decodeRelayDomain(_ value: String) -> String {
        let domain = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard domain.hasSuffix(".com") else {
            return domain
        }
        let body = String(domain.dropLast(4))
        let letters = body.unicodeScalars.filter({ $0 >= "a" && $0 <= "z" }).count
        let shift = letters % 26
        var result = String.UnicodeScalarView()
        for scalar in body.unicodeScalars {
            if scalar >= "a" && scalar <= "z" {
                let offset = (Int(scalar.value - 97) - shift + 26) % 26
                result.append(Unicode.Scalar(UInt32(97 + offset))!)
            } else {
                result.append(scalar)
            }
        }
        return String(result) + ".co.uk"
    }
    
    static func isValidRelayDomain(_ value: String) -> Bool {
        if value.isEmpty || value.count > 253 {
            return false
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count < 2 {
            return false
        }
        for label in labels {
            if label.isEmpty || label.count > 63 || label.hasPrefix("-") || label.hasSuffix("-") {
                return false
            }
            for scalar in label.unicodeScalars {
                if !(scalar >= "a" && scalar <= "z") && !(scalar >= "0" && scalar <= "9") && scalar != "-" {
                    return false
                }
            }
        }
        guard let tld = labels.last, tld.count >= 2 else {
            return false
        }
        return tld.unicodeScalars.contains(where: { $0 >= "a" && $0 <= "z" })
    }
    
    /// `https://host/path`, `host/path` and `host` all reduce to the host, lowercased. An
    /// empty or malformed value becomes "" (meaning "automatic").
    public static func normalizeDomain(_ value: String) -> String {
        var domain = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = domain.range(of: "://") {
            domain = String(domain[range.upperBound...])
        }
        if let index = domain.firstIndex(of: "/") {
            domain = String(domain[..<index])
        }
        if domain.isEmpty || domain.count > 253 || !domain.contains(".") {
            return ""
        }
        for label in domain.split(separator: ".", omittingEmptySubsequences: false) {
            if label.isEmpty || label.count > 63 || label.hasPrefix("-") || label.hasSuffix("-") {
                return ""
            }
            for scalar in label.unicodeScalars {
                if !(scalar >= "a" && scalar <= "z") && !(scalar >= "0" && scalar <= "9") && scalar != "-" {
                    return ""
                }
            }
        }
        return domain
    }
}
