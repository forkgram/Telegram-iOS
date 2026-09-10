import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import AlertUI
import PresentationDataUtils

public final class AuthorizationSequenceQrLoginController: ViewController {
    private var controllerNode: AuthorizationSequenceQrLoginControllerNode {
        return self.displayNode as! AuthorizationSequenceQrLoginControllerNode
    }

    private let sharedContext: SharedAccountContext
    private var account: UnauthorizedAccount
    private let presentationData: PresentationData

    public var accountUpdated: ((UnauthorizedAccount) -> Void)?
    public var loginWithPhone: (() -> Void)?

    private let exportTokenDisposable = MetaDisposable()
    private let tokenEventsDisposable = MetaDisposable()
    private var didAppear = false

    public init(sharedContext: SharedAccountContext, account: UnauthorizedAccount, presentationData: PresentationData, back: @escaping () -> Void) {
        self.sharedContext = sharedContext
        self.account = account
        self.presentationData = presentationData

        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: AuthorizationSequenceController.navigationBarTheme(presentationData.theme), strings: NavigationBarStrings(presentationStrings: presentationData.strings)))

        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        self.statusBar.statusBarStyle = presentationData.theme.intro.statusBarStyle.style

        self.attemptNavigation = { _ in
            return false
        }
        self.navigationBar?.backPressed = {
            back()
        }
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.exportTokenDisposable.dispose()
        self.tokenEventsDisposable.dispose()
    }

    override public func loadDisplayNode() {
        self.displayNode = AuthorizationSequenceQrLoginControllerNode(theme: self.presentationData.theme, strings: self.presentationData.strings)
        self.displayNodeDidLoad()

        self.controllerNode.loginWithPhone = { [weak self] in
            self?.loginWithPhone?()
        }
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if !self.didAppear {
            self.didAppear = true
            self.subscribeToTokenEvents()
            self.refreshToken()
        }
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        self.controllerNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }

    private func subscribeToTokenEvents() {
        self.tokenEventsDisposable.set((self.account.updateLoginTokenEvents
        |> deliverOnMainQueue).startStrict(next: { [weak self] _ in
            self?.refreshToken()
        }))
    }

    private func refreshToken() {
        let sharedContext = self.sharedContext
        let account = self.account

        let tokenSignal = sharedContext.activeAccountContexts
        |> castError(ExportAuthTransferTokenError.self)
        |> take(1)
        |> mapToSignal { activeAccountsAndInfo -> Signal<ExportAuthTransferTokenResult, ExportAuthTransferTokenError> in
            let (_, activeAccounts, _) = activeAccountsAndInfo
            let otherUserIds = activeAccounts
                .map({ $0.1.account })
                .filter({ $0.testingEnvironment == account.testingEnvironment })
                .map({ $0.peerId.id })

            return TelegramEngineUnauthorized(account: account).auth.exportAuthTransferToken(accountManager: sharedContext.accountManager, otherAccountUserIds: otherUserIds, syncContacts: false)
        }

        self.exportTokenDisposable.set((tokenSignal
        |> deliverOnMainQueue).startStrict(next: { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case let .displayToken(token):
                self.controllerNode.updateUrl(qrLoginUrl(token: token))

                let timestamp = Int32(Date().timeIntervalSince1970)
                let timeout = max(5, token.validUntil - timestamp)
                self.exportTokenDisposable.set((Signal<Never, NoError>.complete()
                |> delay(Double(timeout), queue: .mainQueue())).startStrict(completed: { [weak self] in
                    self?.refreshToken()
                }))
            case let .changeAccountAndRetry(updatedAccount):
                self.exportTokenDisposable.set(nil)
                self.account = updatedAccount
                self.accountUpdated?(updatedAccount)
                self.subscribeToTokenEvents()
                self.refreshToken()
            case .loggedIn:
                self.exportTokenDisposable.set(nil)
                self.tokenEventsDisposable.set(nil)
            case let .passwordRequested(updatedAccount):
                self.exportTokenDisposable.set(nil)
                self.tokenEventsDisposable.set(nil)
                self.account = updatedAccount
                self.accountUpdated?(updatedAccount)
            }
        }, error: { [weak self] error in
            guard let self else {
                return
            }
            let text: String
            switch error {
            case .limitExceeded:
                text = self.presentationData.strings.Login_CodeFloodError
            case .generic:
                text = self.presentationData.strings.Login_UnknownError
            }
            self.present(textAlertController(sharedContext: self.sharedContext, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
        }))
    }
}

private func qrLoginUrl(token: AuthTransferExportedToken) -> String {
    var tokenString = token.value.base64EncodedString()
    tokenString = tokenString.replacingOccurrences(of: "+", with: "-")
    tokenString = tokenString.replacingOccurrences(of: "/", with: "_")
    return "tg://login?token=\(tokenString)"
}
