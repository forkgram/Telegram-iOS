import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import ItemListPeerItem
import PresentationDataUtils
import AccountContext
import AccountUtils
import AlertUI
import HiddenAccounts
import PasscodeUI

private final class HiddenAccountsControllerArguments {
    let context: AccountContext
    let setUpAppPasscode: () -> Void
    let toggleStealthMode: (Bool) -> Void
    let toggleRestrictSettings: (Bool) -> Void
    let openAccount: (AccountContext, EnginePeer, Bool) -> Void

    init(
        context: AccountContext,
        setUpAppPasscode: @escaping () -> Void,
        toggleStealthMode: @escaping (Bool) -> Void,
        toggleRestrictSettings: @escaping (Bool) -> Void,
        openAccount: @escaping (AccountContext, EnginePeer, Bool) -> Void
    ) {
        self.context = context
        self.setUpAppPasscode = setUpAppPasscode
        self.toggleStealthMode = toggleStealthMode
        self.toggleRestrictSettings = toggleRestrictSettings
        self.openAccount = openAccount
    }
}

private enum HiddenAccountsSection: Int32 {
    case options
    case accounts
}

private enum HiddenAccountsEntry: ItemListNodeEntry {
    case optionsHeader(PresentationTheme, String)
    case setPasscode(PresentationTheme, String)
    case stealthMode(PresentationTheme, String, Bool, Bool)
    case restrictSettings(PresentationTheme, String, Bool, Bool)
    case optionsInfo(PresentationTheme, String)

    case accountsHeader(PresentationTheme, String)
    case account(Int32, PresentationTheme, AccountContext, EnginePeer, String, Bool)
    case accountsInfo(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .optionsHeader, .setPasscode, .stealthMode, .restrictSettings, .optionsInfo:
            return HiddenAccountsSection.options.rawValue
        case .accountsHeader, .account, .accountsInfo:
            return HiddenAccountsSection.accounts.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .optionsHeader:
            return 0
        case .setPasscode:
            return 1
        case .stealthMode:
            return 2
        case .restrictSettings:
            return 3
        case .optionsInfo:
            return 4
        case .accountsHeader:
            return 5
        case let .account(index, _, _, _, _, _):
            return 6 + index
        case .accountsInfo:
            return Int32.max
        }
    }

    static func ==(lhs: HiddenAccountsEntry, rhs: HiddenAccountsEntry) -> Bool {
        switch lhs {
        case let .optionsHeader(lhsTheme, lhsText):
            if case let .optionsHeader(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                return true
            } else {
                return false
            }
        case let .setPasscode(lhsTheme, lhsText):
            if case let .setPasscode(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                return true
            } else {
                return false
            }
        case let .stealthMode(lhsTheme, lhsText, lhsValue, lhsEnabled):
            if case let .stealthMode(rhsTheme, rhsText, rhsValue, rhsEnabled) = rhs, lhsTheme === rhsTheme, lhsText == rhsText, lhsValue == rhsValue, lhsEnabled == rhsEnabled {
                return true
            } else {
                return false
            }
        case let .restrictSettings(lhsTheme, lhsText, lhsValue, lhsEnabled):
            if case let .restrictSettings(rhsTheme, rhsText, rhsValue, rhsEnabled) = rhs, lhsTheme === rhsTheme, lhsText == rhsText, lhsValue == rhsValue, lhsEnabled == rhsEnabled {
                return true
            } else {
                return false
            }
        case let .optionsInfo(lhsTheme, lhsText):
            if case let .optionsInfo(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                return true
            } else {
                return false
            }
        case let .accountsHeader(lhsTheme, lhsText):
            if case let .accountsHeader(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                return true
            } else {
                return false
            }
        case let .account(lhsIndex, lhsTheme, lhsContext, lhsPeer, lhsLabel, lhsIsHidden):
            if case let .account(rhsIndex, rhsTheme, rhsContext, rhsPeer, rhsLabel, rhsIsHidden) = rhs, lhsIndex == rhsIndex, lhsTheme === rhsTheme, lhsContext === rhsContext, lhsPeer == rhsPeer, lhsLabel == rhsLabel, lhsIsHidden == rhsIsHidden {
                return true
            } else {
                return false
            }
        case let .accountsInfo(lhsTheme, lhsText):
            if case let .accountsInfo(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                return true
            } else {
                return false
            }
        }
    }

    static func <(lhs: HiddenAccountsEntry, rhs: HiddenAccountsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! HiddenAccountsControllerArguments
        switch self {
        case let .optionsHeader(_, text), let .accountsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .setPasscode(_, text):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: text, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.setUpAppPasscode()
            })
        case let .stealthMode(_, text, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: text, value: value, enableInteractiveChanges: false, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleStealthMode(value)
            })
        case let .restrictSettings(_, text, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: text, value: value, enableInteractiveChanges: false, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleRestrictSettings(value)
            })
        case let .optionsInfo(_, text), let .accountsInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .account(_, _, context, peer, label, isHidden):
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: PresentationDateTimeFormat(), nameDisplayOrder: .firstLast, context: context, peer: peer, height: .generic, aliasHandling: .standard, nameStyle: .plain, presence: nil, text: .none, label: .disclosure(label), editing: ItemListPeerItemEditing(editable: false, editing: false, revealed: false), revealOptions: nil, switchValue: nil, enabled: true, selectable: true, sectionId: self.section, action: {
                arguments.openAccount(context, peer, isHidden)
            }, setPeerIdWithRevealedOptions: { _, _ in }, removePeer: { _ in })
        }
    }
}

private func hiddenAccountsControllerEntries(
    presentationData: PresentationData,
    settings: HiddenAccountsSettings,
    hasAppPasscode: Bool,
    requiredCodeType: HiddenAccountCodeType,
    accounts: [(AccountContext, EnginePeer)]
) -> [HiddenAccountsEntry] {
    var entries: [HiddenAccountsEntry] = []
    let theme = presentationData.theme
    let strings = presentationData.strings

    let hasHiddenAccounts = !settings.entries.isEmpty

    entries.append(.optionsHeader(theme, strings.HiddenAccounts_OptionsHeader))
    if !hasAppPasscode {
        entries.append(.setPasscode(theme, strings.HiddenAccounts_SetAppPasscode))
    }
    entries.append(.stealthMode(theme, strings.HiddenAccounts_StealthMode, settings.stealthMode, !hasAppPasscode))
    entries.append(.restrictSettings(theme, strings.HiddenAccounts_RestrictSettings, settings.restrictSettingsToHiddenAccounts, hasHiddenAccounts))

    let optionsInfo: String
    if hasAppPasscode {
        optionsInfo = strings.HiddenAccounts_PasscodeModeInfo(codeTypeDescription(requiredCodeType, strings: strings)).string
    } else if settings.stealthMode {
        optionsInfo = strings.HiddenAccounts_StealthModeInfo(codeTypeDescription(requiredCodeType, strings: strings)).string
    } else {
        optionsInfo = strings.HiddenAccounts_NeedsPasscodeOrStealthMode
    }
    entries.append(.optionsInfo(theme, optionsInfo))

    entries.append(.accountsHeader(theme, strings.HiddenAccounts_AccountsHeader))
    var index: Int32 = 0
    for (context, peer) in accounts {
        let isHidden = settings.isHidden(accountId: context.account.id.int64)
        let label = isHidden ? strings.HiddenAccounts_StateHidden : strings.HiddenAccounts_StateVisible
        entries.append(.account(index, theme, context, peer, label, isHidden))
        index += 1
    }
    var accountsInfo = strings.HiddenAccounts_AccountsInfo
    let hasStaleCodes = hasAppPasscode && settings.entries.contains(where: { $0.codeType != requiredCodeType })
    if hasStaleCodes {
        accountsInfo += "\n\n" + strings.HiddenAccounts_StaleCodeTypeInfo(codeTypeDescription(requiredCodeType, strings: strings)).string
    }
    entries.append(.accountsInfo(theme, accountsInfo))

    return entries
}

private func codeTypeDescription(_ type: HiddenAccountCodeType, strings: PresentationStrings) -> String {
    switch type {
    case .digits4:
        return strings.HiddenAccounts_CodeType4Digits
    case .digits6:
        return strings.HiddenAccounts_CodeType6Digits
    case .alphanumeric:
        return strings.HiddenAccounts_CodeTypeAlphanumeric
    }
}

private func passcodeFieldType(_ type: HiddenAccountCodeType) -> PasscodeEntryFieldType {
    switch type {
    case .digits4:
        return .digits4
    case .digits6:
        return .digits6
    case .alphanumeric:
        return .alphanumeric
    }
}

private func passcodeFieldShape(_ type: HiddenAccountCodeType) -> PostboxAccessChallengeData {
    if let requiredLength = type.requiredLength {
        return .numericalPassword(value: String(repeating: "0", count: requiredLength))
    }
    return .plaintextPassword(value: "")
}

public func hiddenAccountsController(context: AccountContext) -> ViewController {
    let hiddenAccounts = context.sharedContext.appLockContext.hiddenAccounts

    var presentControllerImpl: ((ViewController) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    var popControllerImpl: (() -> Void)?
    var dismissImpl: (() -> Void)?

    let presentError: (String) -> Void = { text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(textAlertController(context: context, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]))
    }

    let requestNewCode: (AccountContext, Bool) -> Void = { accountContext, isChanging in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let requiredType = hiddenAccounts.requiredCodeType
        let setupController = PasscodeSetupController(context: context, mode: .setup(change: isChanging, passcodeFieldType(requiredType)))
        setupController.allowsPasscodeTypeSelection = false
        setupController.titleOverride = presentationData.strings.HiddenAccounts_EnterUnlockCode(codeTypeDescription(requiredType, strings: presentationData.strings)).string
        setupController.title = isChanging ? presentationData.strings.HiddenAccounts_ChangeUnlockCode : presentationData.strings.HiddenAccounts_HideAccount
        setupController.complete = { code, _ in
            let accountId = accountContext.account.id
            switch hiddenAccounts.validateNewCode(accountId: accountId, code: code) {
            case .valid:
                break
            case let .malformed(requiredType):
                popControllerImpl?()
                presentError(presentationData.strings.HiddenAccounts_InvalidUnlockCode(codeTypeDescription(requiredType, strings: presentationData.strings)).string)
                return
            case .duplicate:
                popControllerImpl?()
                presentError(presentationData.strings.HiddenAccounts_DuplicateUnlockCode)
                return
            case .matchesAppPasscode:
                popControllerImpl?()
                presentError(presentationData.strings.HiddenAccounts_CodeMatchesAppPasscode)
                return
            }

            let _ = (hiddenAccounts.setCode(accountId: accountId, code: code)
            |> deliverOnMainQueue).start(completed: {
                popControllerImpl?()
            })
        }
        pushControllerImpl?(setupController)
    }

    let requestCurrentCode: (AccountContext, @escaping () -> Void) -> Void = { accountContext, completion in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let entryController = PasscodeSetupController(context: context, mode: .entry(passcodeFieldShape(hiddenAccounts.codeType(accountId: accountContext.account.id))))
        entryController.titleOverride = presentationData.strings.HiddenAccounts_EnterCurrentUnlockCode
        entryController.title = presentationData.strings.HiddenAccounts_Title
        entryController.check = { code in
            guard hiddenAccounts.verifyCode(accountId: accountContext.account.id, code: code) else {
                return false
            }
            popControllerImpl?()
            completion()
            return true
        }
        pushControllerImpl?(entryController)
    }

    let arguments = HiddenAccountsControllerArguments(context: context, setUpAppPasscode: {
        let _ = passcodeOptionsAccessController(context: context, pushController: { controller in
            pushControllerImpl?(controller)
        }, completion: { _ in
            popControllerImpl?()
        }).start(next: { controller in
            if let controller {
                pushControllerImpl?(controller)
            }
        })
    }, toggleStealthMode: { value in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        if value, hiddenAccounts.hasAppPasscode {
            presentError(presentationData.strings.HiddenAccounts_StealthModeRequiresNoPasscode)
            return
        }
        if !value, !hiddenAccounts.hasAppPasscode, !hiddenAccounts.currentSettings.entries.isEmpty {
            presentError(presentationData.strings.HiddenAccounts_DisableStealthNeedsPasscode)
            return
        }
        let _ = hiddenAccounts.setStealthMode(value).start()
    }, toggleRestrictSettings: { value in
        let _ = hiddenAccounts.setRestrictSettingsToHiddenAccounts(value).start()
    }, openAccount: { accountContext, peer, isHidden in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        if !isHidden {
            guard hiddenAccounts.isAvailable else {
                presentError(presentationData.strings.HiddenAccounts_NeedsPasscodeOrStealthMode)
                return
            }
            let otherVisibleAccounts = context.sharedContext.activeAccountContexts
            let _ = (otherVisibleAccounts
            |> take(1)
            |> deliverOnMainQueue).start(next: { _, accounts, _ in
                let remainingVisible = accounts.contains(where: { $0.0 != accountContext.account.id && !hiddenAccounts.isHidden(accountId: $0.0) })
                if !remainingVisible {
                    presentError(presentationData.strings.HiddenAccounts_NeedVisibleAccount)
                    return
                }
                requestNewCode(accountContext, false)
            })
            return
        }

        requestCurrentCode(accountContext, {
            let actionSheet = ActionSheetController(presentationData: presentationData)
            actionSheet.setItemGroups([ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)),
                ActionSheetButtonItem(title: presentationData.strings.HiddenAccounts_ChangeUnlockCode, color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    requestNewCode(accountContext, true)
                }),
                ActionSheetButtonItem(title: presentationData.strings.HiddenAccounts_ShowAccount, color: .destructive, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    let _ = hiddenAccounts.removeHiddenAccount(accountId: accountContext.account.id).start()
                })
            ]), ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])])
            presentControllerImpl?(actionSheet)
        })
    })

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        hiddenAccounts.settings,
        context.sharedContext.accountManager.accessChallengeData(),
        activeAccountsAndPeers(context: context, includePrimary: true, includeHidden: true)
    )
    |> map { presentationData, settings, accessChallengeData, accountsAndPeers -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let accounts = accountsAndPeers.1.map { ($0.0, $0.1) }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(presentationData.strings.HiddenAccounts_Title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: hiddenAccountsControllerEntries(presentationData: presentationData, settings: settings, hasAppPasscode: accessChallengeData.data.isLockable, requiredCodeType: hiddenAccounts.requiredCodeType, accounts: accounts), style: .blocks, animateChanges: true)

        return (controllerState, (listState, arguments))
    }
    |> afterNext { _ in
        let settings = hiddenAccounts.currentSettings
        if settings.restrictSettingsToHiddenAccounts, !settings.isHidden(accountId: context.account.id.int64) {
            dismissImpl?()
        }
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    popControllerImpl = { [weak controller] in
        guard let controller else {
            return
        }
        (controller.navigationController as? NavigationController)?.popToViewController(controller, animated: true)
    }
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    return controller
}
