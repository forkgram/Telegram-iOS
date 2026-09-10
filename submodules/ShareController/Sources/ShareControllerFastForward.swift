import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit
import AccountContext

private func fastForwardCopyableMedia(_ message: Message) -> Media? {
    for media in message.media {
        if media is TelegramMediaImage || media is TelegramMediaFile || media is TelegramMediaContact || media is TelegramMediaMap {
            return media
        }
        if media is TelegramMediaWebpage {
            continue
        }
        return nil
    }
    return nil
}

private func fastForwardIsGroupable(_ media: Media) -> Bool {
    if media is TelegramMediaImage {
        return true
    }
    if let file = media as? TelegramMediaFile {
        return !file.isSticker && !file.isCustomEmoji && !file.isVoice && !file.isInstantVideo && !file.isAnimated
    }
    return false
}

public func fastForwardCanCopy(_ message: Message) -> Bool {
    if fastForwardCopyableMedia(message) != nil {
        return true
    }
    return !message.text.isEmpty
}

func shareSubjectSupportsFastForward(_ subject: ShareControllerSubject) -> Bool {
    switch subject {
    case let .messages(messages):
        return messages.contains(where: fastForwardCanCopy)
    case let .media(mediaReference, _):
        if case .message = mediaReference {
            return true
        }
        return false
    default:
        return false
    }
}

public func fastForwardGroupableCount(_ messages: [Message]) -> Int {
    var count = 0
    for message in messages {
        if let media = fastForwardCopyableMedia(message), fastForwardIsGroupable(media) {
            count += 1
        }
    }
    return count
}

func fastForwardCanDeleteOriginals(context: AccountContext, messages: [Message]) -> Signal<Bool, NoError> {
    let messageIds = Set(messages.map { $0.id })
    if messageIds.isEmpty {
        return .single(false)
    }
    return context.sharedContext.chatAvailableMessageActions(
        engine: context.engine,
        accountPeerId: context.account.peerId,
        messageIds: messageIds,
        keepUpdated: false
    )
    |> take(1)
    |> map { actions -> Bool in
        if actions.disableDelete {
            return false
        }
        return !actions.options.intersection([.deleteLocally, .deleteGlobally]).isEmpty
    }
}

public func fastForwardEnqueueMessages(
    messages: [Message],
    comment: String,
    threadId: Int64?,
    options: ShareControllerFastForwardOptions
) -> [EnqueueMessage] {
    var result: [EnqueueMessage] = []

    var groupingKeys: [Int64: Int64] = [:]
    var forcedGroupingKey: Int64?
    var forcedGroupingCount = 0
    var groupedCounts: [Int64: Int] = [:]
    var isFirstCopy = true

    for message in messages {
        guard let media = fastForwardCopyableMedia(message) else {
            if message.text.isEmpty {
                result.append(.forward(source: message.id, threadId: threadId, grouping: .auto, attributes: [], correlationId: nil))
            } else {
                var attributes: [MessageAttribute] = []
                for attribute in message.attributes {
                    if let attribute = attribute as? TextEntitiesMessageAttribute {
                        attributes.append(attribute)
                    }
                }
                let text: String
                if options.removeCaptions {
                    text = isFirstCopy ? comment : ""
                    attributes.removeAll()
                    if text.isEmpty {
                        continue
                    }
                } else {
                    text = message.text
                }
                isFirstCopy = false
                result.append(.message(text: text, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
            }
            continue
        }

        var localGroupingKey: Int64?
        if fastForwardIsGroupable(media) {
            if options.groupIntoAlbum {
                if forcedGroupingKey == nil || forcedGroupingCount >= ShareControllerFastForwardOptions.albumSizeLimit {
                    forcedGroupingKey = Int64.random(in: Int64.min ... Int64.max)
                    forcedGroupingCount = 0
                }
                forcedGroupingCount += 1
                localGroupingKey = forcedGroupingKey
            } else if let sourceGroupingKey = message.groupingKey {
                if let existing = groupingKeys[sourceGroupingKey] {
                    localGroupingKey = existing
                } else {
                    let key = Int64.random(in: Int64.min ... Int64.max)
                    groupingKeys[sourceGroupingKey] = key
                    localGroupingKey = key
                }
            }
        }
        if let localGroupingKey {
            groupedCounts[localGroupingKey] = (groupedCounts[localGroupingKey] ?? 0) + 1
        }

        var attributes: [MessageAttribute] = []
        let text: String
        if options.removeCaptions {
            text = isFirstCopy ? comment : ""
        } else {
            text = message.text
            for attribute in message.attributes {
                if let attribute = attribute as? TextEntitiesMessageAttribute {
                    attributes.append(attribute)
                }
            }
        }
        isFirstCopy = false

        let mediaReference: AnyMediaReference
        if media is TelegramMediaContact || media is TelegramMediaMap {
            mediaReference = .standalone(media: media)
        } else {
            mediaReference = .message(message: MessageReference(message), media: media)
        }

        result.append(.message(text: text, attributes: attributes, inlineStickers: [:], mediaReference: mediaReference, threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: localGroupingKey, correlationId: nil, bubbleUpEmojiOrStickersets: []))
    }

    let singleGroupingKeys = Set(groupedCounts.filter({ $0.value < 2 }).keys)
    if !singleGroupingKeys.isEmpty {
        result = result.map { message in
            if case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = message, let localGroupingKey, singleGroupingKeys.contains(localGroupingKey) {
                return .message(text: text, attributes: attributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: nil, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
            }
            return message
        }
    }

    return result
}

func fastForwardDraftReply(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64?) -> Signal<EngineMessageReplySubject?, NoError> {
    return context.engine.peers.getOpaqueChatInterfaceState(peerId: peerId, threadId: threadId)
    |> take(1)
    |> map { state -> EngineMessageReplySubject? in
        guard let replySubject = state?.synchronizeableInputState?.replySubject else {
            return nil
        }
        guard replySubject.messageId.peerId == peerId else {
            return nil
        }
        return replySubject
    }
}

func fastForwardClearDraft(context: AccountContext, peerId: EnginePeer.Id, threadId: Int64?) -> Signal<Never, NoError> {
    return context.engine.peers.setOpaqueChatInterfaceState(
        peerId: peerId,
        threadId: threadId,
        state: OpaqueChatInterfaceState(
            opaqueData: nil,
            historyScrollMessageIndex: nil,
            mediaDraftState: nil,
            synchronizeableInputState: nil
        )
    )
}

func fastForwardDeleteOriginals(context: AccountContext, messages: [Message]) -> Signal<Int, NoError> {
    let messageIds = Set(messages.map { $0.id })
    if messageIds.isEmpty {
        return .single(0)
    }
    return context.sharedContext.chatAvailableMessageActions(
        engine: context.engine,
        accountPeerId: context.account.peerId,
        messageIds: messageIds,
        keepUpdated: false
    )
    |> take(1)
    |> mapToSignal { actions -> Signal<Int, NoError> in
        let type: InteractiveMessagesDeletionType
        if actions.options.contains(.deleteGlobally) {
            type = .forEveryone
        } else if actions.options.contains(.deleteLocally) {
            type = .forLocalPeer
        } else {
            return .single(0)
        }
        return context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: type)
        |> map { _ -> Int in
            return messageIds.count
        }
    }
}
