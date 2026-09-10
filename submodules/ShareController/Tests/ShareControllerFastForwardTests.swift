import XCTest
import Postbox
import TelegramCore
import AccountContext
import ShareController

private let testPeerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(1))

private func makeMessage(
    id: Int32,
    text: String = "",
    entities: [MessageTextEntity] = [],
    media: [Media] = [],
    groupingKey: Int64? = nil
) -> Message {
    var attributes: [MessageAttribute] = []
    if !entities.isEmpty {
        attributes.append(TextEntitiesMessageAttribute(entities: entities))
    }
    return Message(
        stableId: UInt32(id),
        stableVersion: 0,
        id: MessageId(peerId: testPeerId, namespace: Namespaces.Message.Cloud, id: id),
        globallyUniqueId: nil,
        groupingKey: groupingKey,
        groupInfo: nil,
        threadId: nil,
        timestamp: id,
        flags: [],
        tags: [],
        globalTags: [],
        localTags: [],
        customTags: [],
        forwardInfo: nil,
        author: nil,
        text: text,
        attributes: attributes,
        media: media,
        peers: SimpleDictionary(),
        associatedMessages: SimpleDictionary(),
        associatedMessageIds: [],
        associatedMedia: [:],
        associatedThreadInfo: nil,
        associatedStories: [:]
    )
}

private func makePhoto(_ id: Int64) -> TelegramMediaImage {
    return TelegramMediaImage(
        imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: id),
        representations: [],
        immediateThumbnailData: nil,
        reference: .cloud(imageId: id, accessHash: id, fileReference: Data()),
        partialReference: nil,
        flags: []
    )
}

private struct CopiedMessage {
    let text: String
    let attributes: [MessageAttribute]
    let mediaReference: AnyMediaReference?
    let localGroupingKey: Int64?
}

private func copiedMessages(_ messages: [EnqueueMessage]) -> [CopiedMessage?] {
    return messages.map { message -> CopiedMessage? in
        guard case let .message(text, attributes, _, mediaReference, _, _, _, localGroupingKey, _, _) = message else {
            return nil
        }
        return CopiedMessage(text: text, attributes: attributes, mediaReference: mediaReference, localGroupingKey: localGroupingKey)
    }
}

final class ShareControllerFastForwardTests: XCTestCase {
    func testCopyKeepsCaptionAndEntities() {
        let entities = [MessageTextEntity(range: 0 ..< 3, type: .Bold)]
        let source = makeMessage(id: 1, text: "abc def", entities: entities, media: [makePhoto(10)])

        let result = fastForwardEnqueueMessages(messages: [source], comment: "", threadId: nil, options: ShareControllerFastForwardOptions(isEnabled: true))

        XCTAssertEqual(result.count, 1)
        guard let copy = copiedMessages(result)[0] else {
            return XCTFail("expected a copy, not a forward")
        }
        XCTAssertEqual(copy.text, "abc def")
        XCTAssertEqual((copy.attributes.first as? TextEntitiesMessageAttribute)?.entities, entities)
        guard case let .message(_, media)? = copy.mediaReference else {
            return XCTFail("expected the media to be referenced through its source message")
        }
        XCTAssertTrue(media is TelegramMediaImage)
    }

    func testSourceAlbumStaysGrouped() {
        let sources = [
            makeMessage(id: 1, media: [makePhoto(10)], groupingKey: 777),
            makeMessage(id: 2, media: [makePhoto(11)], groupingKey: 777),
            makeMessage(id: 3, media: [makePhoto(12)])
        ]

        let result = copiedMessages(fastForwardEnqueueMessages(messages: sources, comment: "", threadId: nil, options: ShareControllerFastForwardOptions(isEnabled: true)))

        XCTAssertEqual(result.count, 3)
        let first = result[0]?.localGroupingKey
        XCTAssertNotNil(first)
        XCTAssertEqual(result[1]?.localGroupingKey, first)
        XCTAssertNil(result[2]?.localGroupingKey ?? nil)
    }

    func testGroupIntoAlbumChunksAtTen() {
        let sources = (1 ... 12).map { makeMessage(id: Int32($0), media: [makePhoto(Int64($0))]) }

        let result = copiedMessages(fastForwardEnqueueMessages(messages: sources, comment: "", threadId: nil, options: ShareControllerFastForwardOptions(isEnabled: true, groupIntoAlbum: true)))

        XCTAssertEqual(result.count, 12)
        let keys = result.map { $0?.localGroupingKey }
        XCTAssertEqual(Set(keys.prefix(10).compactMap { $0 }).count, 1)
        XCTAssertEqual(Set(keys.suffix(2).compactMap { $0 }).count, 1)
        XCTAssertNotEqual(keys[0], keys[10])
    }

    func testSingleItemNeverBecomesAnAlbum() {
        let sources = [makeMessage(id: 1, media: [makePhoto(10)], groupingKey: 777)]

        let result = copiedMessages(fastForwardEnqueueMessages(messages: sources, comment: "", threadId: nil, options: ShareControllerFastForwardOptions(isEnabled: true, groupIntoAlbum: true)))

        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0]?.localGroupingKey ?? nil)
    }

    func testRemoveCaptionsMovesCommentOntoFirstCopyOnly() {
        let sources = [
            makeMessage(id: 1, text: "first caption", media: [makePhoto(10)]),
            makeMessage(id: 2, text: "second caption", media: [makePhoto(11)])
        ]

        let result = copiedMessages(fastForwardEnqueueMessages(messages: sources, comment: "typed comment", threadId: nil, options: ShareControllerFastForwardOptions(isEnabled: true, removeCaptions: true)))

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0]?.text, "typed comment")
        XCTAssertEqual(result[1]?.text, "")
        XCTAssertTrue(result[0]?.attributes.isEmpty ?? false)
    }

    func testRemoveCaptionsDropsTextOnlyMessages() {
        let sources = [
            makeMessage(id: 1, media: [makePhoto(10)]),
            makeMessage(id: 2, text: "just text")
        ]

        let result = fastForwardEnqueueMessages(messages: sources, comment: "", threadId: nil, options: ShareControllerFastForwardOptions(isEnabled: true, removeCaptions: true))

        XCTAssertEqual(result.count, 1)
    }

    func testGroupableCountIgnoresWhatCannotBeAlbumed() {
        let voice = TelegramMediaFile(
            fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: 1),
            partialReference: nil,
            resource: EmptyMediaResource(),
            previewRepresentations: [],
            videoThumbnails: [],
            immediateThumbnailData: nil,
            mimeType: "audio/ogg",
            size: nil,
            attributes: [.Audio(isVoice: true, duration: 1, title: nil, performer: nil, waveform: nil)],
            alternativeRepresentations: []
        )
        let sources = [
            makeMessage(id: 1, media: [makePhoto(10)]),
            makeMessage(id: 2, media: [voice]),
            makeMessage(id: 3, text: "plain text")
        ]

        XCTAssertEqual(fastForwardGroupableCount(sources), 1)
        XCTAssertEqual(fastForwardGroupableCount([sources[0], makeMessage(id: 4, media: [makePhoto(11)])]), 2)
    }

    func testUncopyableMediaFallsBackToForward() {
        let sources = [makeMessage(id: 1, media: [TelegramMediaDice(emoji: "🎲")])]

        let result = fastForwardEnqueueMessages(messages: sources, comment: "", threadId: nil, options: ShareControllerFastForwardOptions(isEnabled: true))

        XCTAssertEqual(result.count, 1)
        guard case let .forward(source, _, _, _, _) = result[0] else {
            return XCTFail("expected a forward fallback")
        }
        XCTAssertEqual(source, sources[0].id)
    }

    func testWebpagePreviewIsSentAsText() {
        let webpage = TelegramMediaWebpage(webpageId: MediaId(namespace: Namespaces.Media.CloudWebpage, id: 1), content: .Pending(0, nil))
        let sources = [makeMessage(id: 1, text: "https://example.com", media: [webpage])]

        let result = copiedMessages(fastForwardEnqueueMessages(messages: sources, comment: "", threadId: nil, options: ShareControllerFastForwardOptions(isEnabled: true)))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]?.text, "https://example.com")
        XCTAssertNil(result[0]?.mediaReference ?? nil)
    }
}
