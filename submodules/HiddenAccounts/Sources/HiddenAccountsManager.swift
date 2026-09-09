import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences

public final class HiddenAccountsManager {
    private struct State {
        var settings: HiddenAccountsSettings = .defaultSettings
        var appPasscode: String?
        var requiredCodeType: HiddenAccountCodeType = .digits4
        var hasAppPasscode: Bool = false

        var unlockedAccountId: AccountRecordId?
        var pendingUnlockAccountId: AccountRecordId?

        var failedSearchAttempts: Int = 0
        var searchRetryDeadline: Double = 0.0
    }

    private static let searchFreeAttempts = 3
    private static let searchRetryStep: Double = 5.0
    private static let searchRetryLimit: Double = 30.0

    private let accountManager: AccountManager<TelegramAccountManagerTypes>
    private let state = Atomic<State>(value: State())

    private let settingsPromise = ValuePromise<HiddenAccountsSettings>(.defaultSettings, ignoreRepeated: true)
    private let unlockedAccountIdPromise = ValuePromise<AccountRecordId?>(nil, ignoreRepeated: true)

    private var settingsDisposable: Disposable?

    public init(accountManager: AccountManager<TelegramAccountManagerTypes>) {
        self.accountManager = accountManager

        self.settingsDisposable = combineLatest(
            hiddenAccountsSettings(accountManager: accountManager),
            accountManager.accessChallengeData()
        ).startStrict(next: { [weak self] settings, accessChallengeData in
            guard let self else {
                return
            }

            var appPasscode: String?
            switch accessChallengeData.data {
            case .none:
                break
            case let .numericalPassword(value), let .plaintextPassword(value):
                appPasscode = value
            }
            let requiredCodeType = HiddenAccountCode.requiredCodeType(forAppPasscode: accessChallengeData.data)
            let hasAppPasscode = accessChallengeData.data.isLockable

            let updatedState = self.state.modify { current in
                var current = current
                current.settings = settings
                current.appPasscode = appPasscode
                current.requiredCodeType = requiredCodeType
                current.hasAppPasscode = hasAppPasscode
                if let id = current.unlockedAccountId, !settings.isHidden(accountId: id.int64) {
                    current.unlockedAccountId = nil
                }
                if let id = current.pendingUnlockAccountId, !settings.isHidden(accountId: id.int64) {
                    current.pendingUnlockAccountId = nil
                }
                return current
            }
            self.settingsPromise.set(settings)
            self.unlockedAccountIdPromise.set(updatedState.unlockedAccountId)

            if !hasAppPasscode && !settings.stealthMode && !settings.entries.isEmpty {
                let _ = self.setStealthMode(true).start()
            }
        })
    }

    deinit {
        self.settingsDisposable?.dispose()
    }

    // MARK: - Settings

    public var settings: Signal<HiddenAccountsSettings, NoError> {
        return self.settingsPromise.get()
    }

    public var currentSettings: HiddenAccountsSettings {
        return self.state.with { $0.settings }
    }

    public var requiredCodeType: HiddenAccountCodeType {
        return self.state.with { $0.requiredCodeType }
    }

    public var hasAppPasscode: Bool {
        return self.state.with { $0.hasAppPasscode }
    }

    public var isAvailable: Bool {
        return self.state.with { $0.hasAppPasscode || $0.settings.stealthMode }
    }

    public func codeType(accountId: AccountRecordId) -> HiddenAccountCodeType {
        guard let entry = self.currentSettings.entry(accountId: accountId.int64) else {
            return self.requiredCodeType
        }
        return entry.codeType
    }

    public var hasStaleCodeTypes: Bool {
        return self.state.with { state in
            return state.hasAppPasscode && state.settings.entries.contains(where: { $0.codeType != state.requiredCodeType })
        }
    }

    public var isSearchUnlockAvailable: Bool {
        return self.state.with { !$0.hasAppPasscode && $0.settings.stealthMode && !$0.settings.entries.isEmpty }
    }

    // MARK: - Visibility

    public func isHidden(accountId: AccountRecordId) -> Bool {
        return self.currentSettings.isHidden(accountId: accountId.int64)
    }

    public func isVisible(accountId: AccountRecordId) -> Bool {
        return self.state.with { state in
            return !state.settings.isHidden(accountId: accountId.int64) || state.unlockedAccountId == accountId
        }
    }

    public var visibilityUpdated: Signal<Void, NoError> {
        return combineLatest(self.settingsPromise.get(), self.unlockedAccountIdPromise.get())
        |> map { _ -> Void in }
    }

    // MARK: - Unlocked session state

    public var unlockedAccountId: Signal<AccountRecordId?, NoError> {
        return self.unlockedAccountIdPromise.get()
    }

    public var currentUnlockedAccountId: AccountRecordId? {
        return self.state.with { $0.unlockedAccountId }
    }

    public func setUnlockedAccountId(_ accountId: AccountRecordId?) {
        let updatedState = self.state.modify { current in
            var current = current
            if let accountId, current.settings.isHidden(accountId: accountId.int64) {
                current.unlockedAccountId = accountId
            } else {
                current.unlockedAccountId = nil
            }
            current.pendingUnlockAccountId = nil
            return current
        }
        self.unlockedAccountIdPromise.set(updatedState.unlockedAccountId)
    }

    public func clearUnlockedAccount() {
        self.setUnlockedAccountId(nil)
    }

    public func accountBecamePrimary(_ accountId: AccountRecordId) {
        var didChange = false
        let updatedState = self.state.modify { current in
            var current = current
            if let unlockedAccountId = current.unlockedAccountId, unlockedAccountId != accountId {
                current.unlockedAccountId = nil
                didChange = true
            }
            return current
        }
        if didChange {
            self.unlockedAccountIdPromise.set(updatedState.unlockedAccountId)
        }
    }

    // MARK: - Unlocking through the passcode screen

    public func prepareUnlockFromPasscode(code: String) -> Bool {
        guard let accountId = self.findAccount(code: code) else {
            return false
        }
        let _ = self.state.modify { current in
            var current = current
            current.pendingUnlockAccountId = accountId
            return current
        }
        return true
    }

    public func consumePendingUnlock() -> AccountRecordId? {
        var pendingAccountId: AccountRecordId?
        let _ = self.state.modify { current in
            var current = current
            pendingAccountId = current.pendingUnlockAccountId
            current.pendingUnlockAccountId = nil
            if let pendingAccountId {
                current.unlockedAccountId = pendingAccountId
            }
            return current
        }
        if let pendingAccountId {
            self.unlockedAccountIdPromise.set(pendingAccountId)
        }
        return pendingAccountId
    }

    // MARK: - Unlocking through chat list search (stealth mode)

    public func tryUnlockFromSearch(query: String) -> AccountRecordId? {
        guard self.isSearchUnlockAvailable else {
            return nil
        }
        guard HiddenAccountCode.couldBeNumericCode(query) else {
            return nil
        }
        let now = CFAbsoluteTimeGetCurrent()
        if self.state.with({ $0.searchRetryDeadline }) > now {
            return nil
        }

        if let accountId = self.findAccount(code: query) {
            let _ = self.state.modify { current in
                var current = current
                current.failedSearchAttempts = 0
                current.searchRetryDeadline = 0.0
                current.unlockedAccountId = accountId
                current.pendingUnlockAccountId = nil
                return current
            }
            self.unlockedAccountIdPromise.set(accountId)
            return accountId
        }

        let _ = self.state.modify { current in
            var current = current
            current.failedSearchAttempts += 1
            let excessAttempts = current.failedSearchAttempts - HiddenAccountsManager.searchFreeAttempts
            if excessAttempts >= 0 {
                let delay = min(Double(excessAttempts + 1) * HiddenAccountsManager.searchRetryStep, HiddenAccountsManager.searchRetryLimit)
                current.searchRetryDeadline = now + delay
            }
            return current
        }
        return nil
    }

    // MARK: - Code management

    public func verifyCode(accountId: AccountRecordId, code: String) -> Bool {
        guard let entry = self.currentSettings.entry(accountId: accountId.int64) else {
            return false
        }
        return HiddenAccountCode.verify(code: code, entry: entry)
    }

    public func validateNewCode(accountId: AccountRecordId, code: String) -> HiddenAccountCodeValidation {
        let requiredType = self.requiredCodeType
        guard HiddenAccountCode.isWellFormed(code, type: requiredType) else {
            return .malformed(requiredType: requiredType)
        }
        for entry in self.currentSettings.entries where entry.accountId != accountId.int64 {
            if HiddenAccountCode.verify(code: code, entry: entry) {
                return .duplicate
            }
        }
        if self.state.with({ $0.appPasscode }) == code {
            return .matchesAppPasscode
        }
        return .valid
    }

    public func setCode(accountId: AccountRecordId, code: String) -> Signal<Never, NoError> {
        guard let entry = HiddenAccountCode.makeEntry(accountId: accountId.int64, code: code, type: self.requiredCodeType) else {
            return .complete()
        }
        return updateHiddenAccountsSettingsInteractively(accountManager: self.accountManager, { settings in
            var settings = settings
            settings.entries.removeAll(where: { $0.accountId == accountId.int64 })
            settings.entries.append(entry)
            return settings
        })
    }

    public func removeHiddenAccount(accountId: AccountRecordId) -> Signal<Never, NoError> {
        return updateHiddenAccountsSettingsInteractively(accountManager: self.accountManager, { settings in
            var settings = settings
            settings.entries.removeAll(where: { $0.accountId == accountId.int64 })
            if settings.entries.isEmpty {
                settings.restrictSettingsToHiddenAccounts = false
            }
            return settings
        })
    }

    public func setStealthMode(_ enabled: Bool) -> Signal<Never, NoError> {
        return updateHiddenAccountsSettingsInteractively(accountManager: self.accountManager, { settings in
            var settings = settings
            settings.stealthMode = enabled
            return settings
        })
    }

    public func setRestrictSettingsToHiddenAccounts(_ enabled: Bool) -> Signal<Never, NoError> {
        return updateHiddenAccountsSettingsInteractively(accountManager: self.accountManager, { settings in
            var settings = settings
            settings.restrictSettingsToHiddenAccounts = enabled && !settings.entries.isEmpty
            return settings
        })
    }

    // MARK: - Internals

    private func findAccount(code: String) -> AccountRecordId? {
        for entry in self.currentSettings.entries where HiddenAccountCode.isWellFormed(code, type: entry.codeType) {
            if HiddenAccountCode.verify(code: code, entry: entry) {
                return AccountRecordId(rawValue: entry.accountId)
            }
        }
        return nil
    }
}
