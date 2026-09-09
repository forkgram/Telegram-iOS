import Foundation
import SwiftSignalKit
import TelegramCore

public enum HiddenAccountCodeType: Int32 {
    case digits4 = 0
    case digits6 = 1
    case alphanumeric = 2

    public var requiredLength: Int? {
        switch self {
        case .digits4:
            return 4
        case .digits6:
            return 6
        case .alphanumeric:
            return nil
        }
    }

    public var isNumeric: Bool {
        switch self {
        case .digits4, .digits6:
            return true
        case .alphanumeric:
            return false
        }
    }
}

public struct HiddenAccountEntry: Equatable, Codable {
    public var accountId: Int64
    public var salt: Data
    public var hash: Data
    public var codeType: HiddenAccountCodeType

    public init(accountId: Int64, salt: Data, hash: Data, codeType: HiddenAccountCodeType) {
        self.accountId = accountId
        self.salt = salt
        self.hash = hash
        self.codeType = codeType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        self.accountId = try container.decode(Int64.self, forKey: "accountId")
        self.salt = try container.decode(Data.self, forKey: "salt")
        self.hash = try container.decode(Data.self, forKey: "hash")
        self.codeType = HiddenAccountCodeType(rawValue: try container.decodeIfPresent(Int32.self, forKey: "codeType") ?? 0) ?? .digits4
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encode(self.accountId, forKey: "accountId")
        try container.encode(self.salt, forKey: "salt")
        try container.encode(self.hash, forKey: "hash")
        try container.encode(self.codeType.rawValue, forKey: "codeType")
    }
}

public struct HiddenAccountsSettings: Equatable, Codable {
    public var stealthMode: Bool
    public var restrictSettingsToHiddenAccounts: Bool
    public var entries: [HiddenAccountEntry]

    public static var defaultSettings: HiddenAccountsSettings {
        return HiddenAccountsSettings(stealthMode: false, restrictSettingsToHiddenAccounts: false, entries: [])
    }

    public init(stealthMode: Bool, restrictSettingsToHiddenAccounts: Bool, entries: [HiddenAccountEntry]) {
        self.stealthMode = stealthMode
        self.restrictSettingsToHiddenAccounts = restrictSettingsToHiddenAccounts
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        self.stealthMode = (try container.decodeIfPresent(Int32.self, forKey: "stealthMode") ?? 0) != 0
        self.restrictSettingsToHiddenAccounts = (try container.decodeIfPresent(Int32.self, forKey: "restrictSettings") ?? 0) != 0
        self.entries = try container.decodeIfPresent([HiddenAccountEntry].self, forKey: "entries") ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encode((self.stealthMode ? 1 : 0) as Int32, forKey: "stealthMode")
        try container.encode((self.restrictSettingsToHiddenAccounts ? 1 : 0) as Int32, forKey: "restrictSettings")
        try container.encode(self.entries, forKey: "entries")
    }

    public func entry(accountId: Int64) -> HiddenAccountEntry? {
        return self.entries.first(where: { $0.accountId == accountId })
    }

    public func isHidden(accountId: Int64) -> Bool {
        return self.entry(accountId: accountId) != nil
    }

    public var hiddenAccountIds: Set<Int64> {
        return Set(self.entries.map(\.accountId))
    }
}

public func hiddenAccountsSettings(accountManager: AccountManager<TelegramAccountManagerTypes>) -> Signal<HiddenAccountsSettings, NoError> {
    return accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.hiddenAccountsSettings])
    |> map { sharedData -> HiddenAccountsSettings in
        return sharedData.entries[ApplicationSpecificSharedDataKeys.hiddenAccountsSettings]?.get(HiddenAccountsSettings.self) ?? .defaultSettings
    }
    |> distinctUntilChanged
}

public func updateHiddenAccountsSettingsInteractively(accountManager: AccountManager<TelegramAccountManagerTypes>, _ f: @escaping (HiddenAccountsSettings) -> HiddenAccountsSettings) -> Signal<Never, NoError> {
    return accountManager.transaction { transaction -> Void in
        transaction.updateSharedData(ApplicationSpecificSharedDataKeys.hiddenAccountsSettings, { entry in
            let currentSettings = entry?.get(HiddenAccountsSettings.self) ?? .defaultSettings
            return SharedPreferencesEntry(f(currentSettings))
        })
    }
    |> ignoreValues
}
