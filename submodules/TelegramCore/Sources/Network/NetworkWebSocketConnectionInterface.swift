import Foundation
import Network
import Security
import CryptoKit

import MtProtoKit
import SwiftSignalKit

/// A connection interface that carries the MTProto transport over a WebSocket connection.
///
/// `MTTcpConnection` owns the MTProto framing (abridged packets, quick acks) and hands this
/// interface the bytes it would otherwise put on a TCP socket. They are sent as WebSocket
/// binary messages, and the messages the endpoint answers with are reassembled into the byte
/// stream `MTTcpConnection`'s reader expects: WebSocket is message oriented, MTProto is not, so
/// the interface keeps a buffer and satisfies exact-length reads from it.
///
/// The upgrade is written by hand rather than through `NWProtocolWebSocket` because the endpoint
/// is not at `/`: Telegram terminates MTProto at `/apiws`, and that is the one part of the
/// handshake Network.framework does not expose.
@available(iOS 12.0, macOS 14.0, *)
final class NetworkWebSocketConnectionInterface: NSObject, MTTcpConnectionInterface {
    private struct ReadRequest {
        let length: Int
        let tag: Int
    }
    
    private final class Impl {
        private let queue: Queue
        
        private weak var delegate: MTTcpConnectionInterfaceDelegate?
        private let delegateQueue: DispatchQueue
        
        private let host: String
        private let port: UInt16
        private let path: String
        
        private var connection: NWConnection?
        private var reportedDisconnection: Bool = false
        private var handshakeCompleted: Bool = false
        
        private var currentInterfaceIsWifi: Bool = true
        
        private var connectTimeoutTimer: SwiftSignalKit.Timer?
        
        private var usageCalculationInfo: MTNetworkUsageCalculationInfo?
        private var networkUsageManager: MTNetworkUsageManager?
        
        private var getLogPrefix: (() -> String)?
        
        private var instanceId: String
        private var logId: String
        
        private var handshakeBuffer = Data()
        private var handshakeKey = ""
        
        private var streamBuffer = Data()
        private var frameBuffer = Data()
        private var pendingPongPayloads: [Data] = []
        
        private var readRequests: [ReadRequest] = []
        private var receiveRequested: Bool = false
        /// MTTcpConnection starts writing as soon as `connectToHost:` returns, before the
        /// upgrade completes; GCDAsyncSocket buffers those writes, so this interface must too.
        /// Dropping them would silently lose the first abridged packet of the connection.
        private var pendingWrites: [Data] = []
        /// The first MTProto write of a connection is the 64-byte obfuscated2 header followed
        /// by the first packet. The endpoints and the reference clients put the header in a
        /// WebSocket message of its own, so the first write is split at 64 bytes.
        private var didSendHeaderFrame: Bool = false
        
        private var receivedAnyPayload: Bool = false
        /// Set when `MTTcpConnection` tears the socket down itself (scheme switch, transport
        /// reset). That is not an endpoint failure, so it must not count as a strike.
        private var requestedDisconnect: Bool = false
        
        /// `Logger` writes files only, and the device syslog is the one channel that can be
        /// read while the phone is locked (AFC refuses the app container). TGBUILD mirrors the
        /// few transport lines to NSLog for that reason.
        private func log(_ text: String) {
            Logger.shared.log("WS", "\(self.logId) \(text)")
            #if TGBUILD
            NSLog("[ws] %@", "\(self.logId) \(text)")
            #endif
        }
        
        init(queue: Queue, host: String, port: UInt16, path: String, delegate: MTTcpConnectionInterfaceDelegate, delegateQueue: DispatchQueue) {
            self.queue = queue
            self.host = host
            self.port = port
            self.path = path
            self.delegate = delegate
            self.delegateQueue = delegateQueue
            let instanceId = String(UUID().uuidString.prefix(8))
            self.instanceId = instanceId
            self.logId = "[WS#\(instanceId) \(host)\(path)]"
        }
        
        deinit {
            if let connection = self.connection {
                self.connection = nil
                connection.cancel()
            }
        }
        
        func setUsageCalculationInfo(_ usageCalculationInfo: MTNetworkUsageCalculationInfo?) {
            if self.usageCalculationInfo !== usageCalculationInfo {
                self.usageCalculationInfo = usageCalculationInfo
                if let usageCalculationInfo = usageCalculationInfo {
                    self.networkUsageManager = MTNetworkUsageManager(info: usageCalculationInfo)
                } else {
                    self.networkUsageManager = nil
                }
            }
        }
        
        func setGetLogPrefix(_ getLogPrefix: (() -> String)?) {
            self.getLogPrefix = getLogPrefix
        }
        
        func connect(timeout: Double) {
            if self.connection != nil {
                self.log("connect ignored: a connection already exists")
                return
            }
            
            if let logPrefix = self.getLogPrefix?(), !logPrefix.isEmpty {
                self.logId = "[WS#\(self.instanceId) \(logPrefix) \(self.host)\(self.path)]"
            }
            
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 5
            tcpOptions.keepaliveCount = 2
            tcpOptions.keepaliveInterval = 5
            
            // No ALPN: the endpoint carries an HTTP/1.1 upgrade, and the reference client
            // (tg-ws-proxy's Android integration) offers no protocol either.
            let tlsOptions = NWProtocolTLS.Options()
            
            let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
            // MTProto does its own proxying; a system proxy would sit in front of the very
            // connection this transport exists to make look like ordinary HTTPS.
            parameters.preferNoProxies = true
            
            guard let endpointPort = NWEndpoint.Port(rawValue: self.port) else {
                self.cancelWithError(error: nil, reason: "invalid port \(self.port)")
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(self.host), port: endpointPort, using: parameters)
            self.connection = connection
            
            let queue = self.queue
            connection.stateUpdateHandler = { [weak self] state in
                queue.async {
                    self?.stateUpdated(state: state)
                }
            }
            connection.pathUpdateHandler = { [weak self] path in
                queue.async {
                    guard let self = self else {
                        return
                    }
                    self.currentInterfaceIsWifi = !path.usesInterfaceType(.cellular)
                }
            }
            
            self.connectTimeoutTimer = SwiftSignalKit.Timer(timeout: timeout, repeat: false, completion: { [weak self] in
                guard let self = self else {
                    return
                }
                self.connectTimeoutTimer = nil
                self.cancelWithError(error: nil, reason: "connect timeout (\(timeout)s)")
            }, queue: self.queue)
            self.connectTimeoutTimer?.start()
            
            self.log("starting WebSocket connection (timeout: \(timeout)s)")
            connection.start(queue: self.queue.queue)
        }
        
        private func stateUpdated(state: NWConnection.State) {
            guard self.connection != nil else {
                self.log("state after teardown (ignored)")
                return
            }
            switch state {
            case .ready:
                self.log("TLS ready, sending upgrade")
                self.sendHandshake()
            case let .failed(error):
                self.cancelWithError(error: error, reason: "connection failed")
            case .cancelled:
                self.cancelWithError(error: nil, reason: "connection cancelled")
            default:
                break
            }
        }
        
        private func sendHandshake() {
            var keyBytes = Data(count: 16)
            let keyResult = keyBytes.withUnsafeMutableBytes { buffer -> Int32 in
                guard let baseAddress = buffer.baseAddress else {
                    return errSecParam
                }
                return SecRandomCopyBytes(kSecRandomDefault, 16, baseAddress)
            }
            if keyResult != errSecSuccess {
                keyBytes = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            }
            self.handshakeKey = keyBytes.base64EncodedString()
            
            var request = "GET \(self.path) HTTP/1.1\r\n"
            request += "Host: \(self.host)\r\n"
            request += "Upgrade: websocket\r\n"
            request += "Connection: Upgrade\r\n"
            request += "Origin: https://web.telegram.org\r\n"
            request += "Sec-WebSocket-Key: \(self.handshakeKey)\r\n"
            request += "Sec-WebSocket-Version: 13\r\n"
            request += "Sec-WebSocket-Protocol: binary\r\n\r\n"
            
            guard let connection = self.connection, let data = request.data(using: .utf8) else {
                self.cancelWithError(error: nil, reason: "no connection for upgrade")
                return
            }
            connection.send(content: data, completion: .contentProcessed({ [weak self] error in
                guard let self = self, let error = error else {
                    return
                }
                self.cancelWithError(error: error, reason: "upgrade send failed")
            }))
            self.receive()
        }
        
        private func receive() {
            guard let connection = self.connection else {
                return
            }
            if self.receiveRequested {
                return
            }
            self.receiveRequested = true
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536, completion: { [weak self] data, _, isComplete, error in
                guard let self = self else {
                    return
                }
                self.receiveRequested = false
                if let data = data, !data.isEmpty {
                    self.contentReceived(data)
                }
                if let error = error {
                    self.cancelWithError(error: error, reason: "receive failed")
                    return
                }
                if isComplete {
                    self.cancelWithError(error: nil, reason: "remote closed the connection")
                    return
                }
                self.receive()
            })
        }
        
        private func contentReceived(_ data: Data) {
            self.networkUsageManager?.addIncomingBytes(UInt(data.count), interface: self.currentInterfaceIsWifi ? MTNetworkUsageManagerInterfaceOther : MTNetworkUsageManagerInterfaceWWAN)
            
            if !self.handshakeCompleted {
                self.handshakeBuffer.append(data)
                guard let headerRange = self.handshakeBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if self.handshakeBuffer.count > 16384 {
                        self.cancelWithError(error: nil, reason: "upgrade response too large")
                    }
                    return
                }
                let headerData = self.handshakeBuffer.subdata(in: 0..<headerRange.lowerBound)
                let leftover = self.handshakeBuffer.subdata(in: headerRange.upperBound..<self.handshakeBuffer.count)
                self.handshakeBuffer.removeAll()
                guard let headerString = String(data: headerData, encoding: .utf8) else {
                    self.cancelWithError(error: nil, reason: "unreadable upgrade response")
                    return
                }
                let lines = headerString.components(separatedBy: "\r\n")
                guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/1.1 101") || statusLine.hasPrefix("HTTP/1.0 101") else {
                    let status = lines.first ?? ""
                    self.cancelWithError(error: nil, reason: "upgrade refused (\(status))")
                    return
                }
                var acceptValue: String?
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    if parts.count == 2, parts[0].lowercased() == "sec-websocket-accept" {
                        acceptValue = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }
                let expectedAccept = Data(Insecure.SHA1.hash(data: Data(self.handshakeKey.utf8) + Data("258EAFA5-E914-47DA-95CA-C5AB0DC85B11".utf8))).base64EncodedString()
                if let acceptValue = acceptValue, acceptValue != expectedAccept {
                    self.cancelWithError(error: nil, reason: "upgrade accept mismatch")
                    return
                }
                
                self.handshakeCompleted = true
                if let connectTimeoutTimer = self.connectTimeoutTimer {
                    self.connectTimeoutTimer = nil
                    connectTimeoutTimer.invalidate()
                }
                self.log("upgraded")
                
                let delegate = self.delegate
                self.delegateQueue.async { [weak delegate] in
                    if let delegate = delegate {
                        delegate.connectionInterfaceDidConnect()
                    }
                }
                if !leftover.isEmpty {
                    self.consumeFrames(leftover)
                }
                let pendingWrites = self.pendingWrites
                self.pendingWrites.removeAll()
                for data in pendingWrites {
                    self.sendMessage(data)
                }
                self.processReadRequests()
                return
            }
            
            self.consumeFrames(data)
            self.processReadRequests()
        }
        
        // MARK: - Frame decoding
        
        private func consumeFrames(_ data: Data) {
            self.frameBuffer.append(data)
            
            let bytes = [UInt8](self.frameBuffer)
            var cursor = 0
            
            while true {
                guard bytes.count - cursor >= 2 else {
                    break
                }
                let opcode = bytes[cursor] & 0x0f
                let isMasked = (bytes[cursor + 1] & 0x80) != 0
                var payloadLength = UInt64(bytes[cursor + 1] & 0x7f)
                var offset = cursor + 2
                if payloadLength == 126 {
                    guard bytes.count - offset >= 2 else {
                        break
                    }
                    payloadLength = (UInt64(bytes[offset]) << 8) | UInt64(bytes[offset + 1])
                    offset += 2
                } else if payloadLength == 127 {
                    guard bytes.count - offset >= 8 else {
                        break
                    }
                    var length: UInt64 = 0
                    for index in offset..<(offset + 8) {
                        length = (length << 8) | UInt64(bytes[index])
                    }
                    payloadLength = length
                    offset += 8
                }
                var maskKey: [UInt8] = []
                if isMasked {
                    guard bytes.count - offset >= 4 else {
                        break
                    }
                    maskKey = Array(bytes[offset..<(offset + 4)])
                    offset += 4
                }
                guard payloadLength <= 8 * 1024 * 1024 else {
                    self.cancelWithError(error: nil, reason: "frame too large (\(payloadLength))")
                    return
                }
                guard UInt64(bytes.count - offset) >= payloadLength else {
                    break
                }
                var payload = Data(bytes[offset..<(offset + Int(payloadLength))])
                cursor = offset + Int(payloadLength)
                if isMasked {
                    payload.withUnsafeMutableBytes { buffer in
                        guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                            return
                        }
                        for index in 0..<buffer.count {
                            baseAddress[index] ^= maskKey[index & 3]
                        }
                    }
                }
                
                switch opcode {
                case 0x1:
                    // Text frames carry no MTProto payload; the endpoint does not send them.
                    break
                case 0x0, 0x2:
                    if !payload.isEmpty {
                        self.receivedAnyPayload = true
                        NetworkWebSocketTransport.shared.reportSuccess(host: self.host)
                        self.streamBuffer.append(payload)
                        self.notifyPartialRead(length: payload.count)
                    }
                case 0x8:
                    self.cancelWithError(error: nil, reason: "endpoint closed the WebSocket")
                    return
                case 0x9:
                    self.sendFrame(opcode: 0xA, payload: payload)
                default:
                    break
                }
            }
            
            if cursor > 0 {
                self.frameBuffer = Data(bytes[cursor...])
            }
        }
        
        // MARK: - Frame encoding
        
        private func sendFrame(opcode: UInt8, payload: Data) {
            guard let connection = self.connection else {
                return
            }
            var frame = Data()
            frame.append(0x80 | opcode)
            let length = payload.count
            if length < 126 {
                frame.append(0x80 | UInt8(length))
            } else if length <= 0xffff {
                frame.append(0x80 | 126)
                frame.append(UInt8((length >> 8) & 0xff))
                frame.append(UInt8(length & 0xff))
            } else {
                frame.append(0x80 | 127)
                var bigLength = UInt64(length).bigEndian
                withUnsafeBytes(of: &bigLength) { buffer in
                    for byte in buffer {
                        frame.append(byte)
                    }
                }
            }
            var maskKey = [UInt8](repeating: 0, count: 4)
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, &maskKey)
            frame.append(contentsOf: maskKey)
            
            var maskedPayload = payload
            maskedPayload.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                for index in 0..<buffer.count {
                    baseAddress[index] ^= maskKey[index & 3]
                }
            }
            frame.append(maskedPayload)
            
            connection.send(content: frame, completion: .contentProcessed({ [weak self] error in
                guard let self = self, let error = error else {
                    return
                }
                self.cancelWithError(error: error, reason: "send failed")
            }))
            self.networkUsageManager?.addOutgoingBytes(UInt(frame.count), interface: self.currentInterfaceIsWifi ? MTNetworkUsageManagerInterfaceOther : MTNetworkUsageManagerInterfaceWWAN)
        }
        
        func write(data: Data) {
            guard self.connection != nil else {
                self.log("write called while connection == nil")
                return
            }
            if !self.handshakeCompleted {
                self.pendingWrites.append(data)
                self.log("write buffered until upgrade completes (\(data.count) bytes)")
                return
            }
            self.sendMessage(data)
        }
        
        private func sendMessage(_ data: Data) {
            if !self.didSendHeaderFrame && data.count > 64 {
                self.didSendHeaderFrame = true
                self.sendFrame(opcode: 0x2, payload: Data(data.prefix(64)))
                self.sendFrame(opcode: 0x2, payload: Data(data.dropFirst(64)))
            } else {
                if !self.didSendHeaderFrame {
                    self.didSendHeaderFrame = true
                }
                self.sendFrame(opcode: 0x2, payload: data)
            }
        }
        
        // MARK: - Read requests
        
        func read(length: Int, timeout: Double, tag: Int) {
            self.readRequests.append(ReadRequest(length: length, tag: tag))
            self.processReadRequests()
        }
        
        private func processReadRequests() {
            while !self.readRequests.isEmpty {
                let request = self.readRequests[0]
                guard self.streamBuffer.count >= request.length else {
                    return
                }
                self.readRequests.removeFirst()
                let chunk = self.streamBuffer.prefix(request.length)
                self.streamBuffer.removeFirst(request.length)
                
                let delegate = self.delegate
                let networkType: Int32 = self.currentInterfaceIsWifi ? 0 : 1
                let tag = request.tag
                self.delegateQueue.async { [weak delegate] in
                    if let delegate = delegate {
                        delegate.connectionInterfaceDidRead(Data(chunk), withTag: tag, networkType: networkType)
                    }
                }
            }
        }
        
        private func notifyPartialRead(length: Int) {
            guard let currentRequest = self.readRequests.first else {
                return
            }
            let delegate = self.delegate
            self.delegateQueue.async { [weak delegate] in
                if let delegate = delegate {
                    delegate.connectionInterfaceDidReadPartialData(ofLength: UInt(length), tag: currentRequest.tag)
                }
            }
        }
        
        // MARK: - Teardown
        
        func disconnect() {
            self.requestedDisconnect = true
            self.cancelWithError(error: nil, reason: "disconnect requested")
        }
        
        func resetDelegate() {
            self.delegate = nil
        }
        
        private func cancelWithError(error: Error?, reason: String) {
            if let connectTimeoutTimer = self.connectTimeoutTimer {
                self.connectTimeoutTimer = nil
                connectTimeoutTimer.invalidate()
            }
            if !self.receivedAnyPayload && !self.requestedDisconnect {
                NetworkWebSocketTransport.shared.reportFailure(host: self.host)
            }
            
            let errorSuffix = error.map({ " error: \($0)" }) ?? ""
            if !self.reportedDisconnection {
                self.reportedDisconnection = true
                self.log("disconnecting: \(reason)\(errorSuffix)")
                let delegate = self.delegate
                self.delegateQueue.async { [weak delegate] in
                    if let delegate = delegate {
                        delegate.connectionInterfaceDidDisconnectWithError(error)
                    }
                }
            } else {
                self.log("already disconnected, ignoring: \(reason)")
            }
            if let connection = self.connection {
                self.connection = nil
                connection.cancel()
            }
        }
    }
    
    private static let sharedQueue = Queue(name: "NetworkWebSocketConnectionInterface")
    
    private let queue: Queue
    private let impl: QueueLocalObject<Impl>
    
    init(host: String, port: UInt16, path: String, delegate: MTTcpConnectionInterfaceDelegate, delegateQueue: DispatchQueue) {
        let queue = NetworkWebSocketConnectionInterface.sharedQueue
        self.queue = queue
        self.impl = QueueLocalObject(queue: queue, generate: {
            return Impl(queue: queue, host: host, port: port, path: path, delegate: delegate, delegateQueue: delegateQueue)
        })
    }
    
    func setGetLogPrefix(_ getLogPrefix: (() -> String)?) {
        self.impl.with { impl in
            impl.setGetLogPrefix(getLogPrefix)
        }
    }
    
    func setUsageCalculationInfo(_ usageCalculationInfo: MTNetworkUsageCalculationInfo?) {
        self.impl.with { impl in
            impl.setUsageCalculationInfo(usageCalculationInfo)
        }
    }
    
    func connect(toHost inHost: String, onPort port: UInt16, viaInterface inInterface: String?, withTimeout timeout: TimeInterval, error errPtr: NSErrorPointer) -> Bool {
        self.impl.with { impl in
            impl.connect(timeout: timeout)
        }
        return true
    }
    
    func write(_ data: Data) {
        self.impl.with { impl in
            impl.write(data: data)
        }
    }
    
    func readData(toLength length: UInt, withTimeout timeout: TimeInterval, tag: Int) {
        self.impl.with { impl in
            impl.read(length: Int(length), timeout: timeout, tag: tag)
        }
    }
    
    func disconnect() {
        self.impl.with { impl in
            impl.disconnect()
        }
    }
    
    func resetDelegate() {
        self.impl.with { impl in
            impl.resetDelegate()
        }
    }
}
