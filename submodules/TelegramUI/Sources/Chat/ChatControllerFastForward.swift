import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import AccountContext

extension ChatControllerImpl {
    func presentFastForward(messages: [Message]) {
        guard !messages.isEmpty else {
            return
        }
        let shareController = self.context.sharedContext.makeShareController(
            context: self.context,
            params: ShareControllerParams(
                subject: .messages(messages),
                externalShare: false,
                immediateExternalShare: false,
                updatedPresentationData: self.updatedPresentationData,
                parentNavigationController: self.effectiveNavigationController,
                fastForward: true
            )
        )
        self.chatDisplayNode.dismissInput()
        self.present(shareController, in: .window(.root))
    }
}
