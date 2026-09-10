# Fast Forward

Port of the Forkgram (Android) *Fast Forward* feature — `90e04293fb`
("Added full implementation of Fast Forward") plus the `replaceForward` setting.

Instead of forwarding a message with a "Forwarded from …" header, Fast Forward **re-sends its
content as the sender's own message**. On the wire that is an ordinary send of the same remote
photo/document, so the file is never re-uploaded.

## Entry points

| Where | What it does |
|---|---|
| Message context menu, right under **Forward** | `interfaceInteraction.fastForwardMessages` → share sheet in Fast Forward mode |
| Selection panel, between **Share** and **Forward** | `interfaceInteraction.fastForwardSelectedMessages` → same, for the whole selection |
| Any share sheet whose subject can be copied | the send button's long-press menu gains the Fast Forward section |

Both chat entry points land in `ChatControllerImpl.presentFastForward(messages:)`
(`submodules/TelegramUI/Sources/Chat/ChatControllerFastForward.swift`), which opens the standard
`ShareController` with `fastForward: true`.

Unlike Android, there is no `replaceForward` setting: the regular **Forward** entry points are
left untouched and Fast Forward is offered next to them.

## Share sheet

The sheet keeps its single wide action button; Android's three floating buttons have no iOS
counterpart. When it is opened in Fast Forward mode the button reads **Fast Forward** and sends
copies. Its long-press menu carries the rest:

| Item | Android equivalent |
|---|---|
| **Send without Sender Name** (only when the sheet was not opened in that mode) | the `anon_forward` button |
| **Send without Text** / **Send with Comment** | the `nontext_forward` button |
| **Group into Album** (toggle) | the group-media button in the selection action bar |
| **Delete Originals** (toggle) | `ShareOptions` ▸ "Delete original messages" |
| **Schedule Message** | — (missing upstream too) |
| **Send Without Sound** | long press on either forward button |
| **Forward with Attribution** (only in Fast Forward mode) | the untouched original Forward |

**The feature is called Fast Forward everywhere except inside this menu.** Next to Forward in a
message's context menu, or as a button in the selection panel, "Fast Forward" is a name; sitting in
a list of send options it is not self-explanatory, so that one item spells the action out as
**Send without Sender Name** (`FastForward.SendWithoutSenderName`). Everything else uses
`FastForward.Title`.

The stock **Show / Hide senders name** checkmarks are dropped wherever Fast Forward is available:
hiding the sender name is precisely what Fast Forward does, so keeping both was two ways to say the
same thing. They survive where Fast Forward cannot stand in (a `.messages` subject that holds
nothing copyable, e.g. only polls).

Two items change their wording with context:

- **Send without Text** becomes **Send with Comment** once the comment field is non-empty, because
  dropping the original captions is what promotes the typed comment onto the first copy — the
  action reads the other way round from the user's side.
- Nothing else in the menu is conditional on text.

Toggles deliberately do **not** dismiss the menu — they mutate `fastForwardOptionsValue`, whose
`ValuePromise` re-emits and rebuilds the item list in place.

`Group into Album` appears only when at least two of the shared messages would actually end up in
an album (`fastForwardGroupableCount`); grouping a single photo is meaningless.
`Delete Originals` appears only once `chatAvailableMessageActions` says the originals are
deletable — that check is asynchronous, so it arrives through the same `ValuePromise` that drives
the rest of the menu. Both toggles live on the sheet's node and reset every time the sheet is
opened, so a destructive option never becomes a sticky setting. `Delete Originals` survives
**Forward with Attribution**, which clears only the copy mode.

## Scheduling

Upstream's share sheet cannot schedule at all. **Schedule Message** opens the standard
`ChatScheduleTimeController` and passes the chosen timestamp down to `transformMessages`, which
attaches an `OutgoingScheduleInfoMessageAttribute` — so it applies to a plain forward just as much
as to a Fast Forward. *Send When Online* is offered only when exactly one recipient is selected,
it is a user, and their presence says they are online; with several recipients one shared "when
online" moment has no meaning.

## What the send path does

`fastForwardEnqueueMessages` (`submodules/ShareController/Sources/ShareControllerFastForward.swift`)
turns source messages into `EnqueueMessage.message` values:

- **Media** becomes `mediaReference: .message(message:media:)`. Contacts and locations have no
  file to reference and go through `.standalone`.
- **Captions** are kept with their `TextEntitiesMessageAttribute`. With `removeCaptions` every
  caption is dropped and the typed comment moves onto the first copy, instead of being sent as
  its own leading message.
- **Grouping**: source albums keep their shape (one fresh `localGroupingKey` per source
  `groupingKey`); `groupIntoAlbum` instead regroups every groupable item into fresh albums of
  ten. A grouping key that ends up covering a single item is dropped, so nothing is posted as a
  one-item album. Stickers, voice notes, video messages and animations are never grouped.
- **Anything that cannot be re-sent** — polls, dice, games, invoices — falls back to a real
  `.forward` rather than being silently skipped. (Android hides Fast Forward entirely for those.)

Three parts of the Android implementation are **not** needed here:

- The manual `messages.sendMultiMedia` request: `enqueueMessages` builds it from `localGroupingKey`.
- The `FILE_REFERENCE_EXPIRED` retry loop (`ForkApi.tlrpcMessages` → patch `file_reference` →
  resend): `PendingMessageManager` already revalidates through the `MessageReference` we pass.
- The serial send queue that preserved ordering: `enqueueMessages` takes the whole batch at once.

## Reply parked in the target chat's draft

Android reads the target chat's draft before sending and, if a reply is parked there, makes the
copies reply to it. `fastForwardDraftReply` does the same via
`engine.peers.getOpaqueChatInterfaceState(peerId:threadId:)` → `synchronizeableInputState.replySubject`,
falling back to the forum topic's root message when there is no draft reply.

**Deliberate difference:** Android clears the whole draft after every Fast Forward.
`fastForwardClearDraft` runs only when a draft reply was actually consumed, so an unrelated
composed draft in the target chat survives.

## Delete Originals

`ShareController` keeps the source messages in `originalsToDelete` and calls
`fastForwardDeleteOriginals` from the same place the sheet decides the share is `.done` — i.e.
once every copy has left `pendingMessageManager`. That is the iOS counterpart of Android's
`ShareOptions.SentWatcher` (which counts `messageReceivedByServer` notifications with a 60 s
timeout).

Revoke-for-everyone is chosen from `chatAvailableMessageActions`: `.deleteGlobally` if allowed,
otherwise `.deleteLocally`, otherwise nothing is deleted.

The confirmation toast is presented through `parentNavigationController`'s top controller,
because the share sheet itself is already dismissed by then — which is why
`presentFastForward` passes `parentNavigationController`.

## Tests

`fastForwardEnqueueMessages` is the one piece of this feature that is pure logic, and none of it
is reachable from a device screenshot, so it has a unit test:

```sh
python3 build-system/Make/Make.py --overrideXcodeVersion \
 test --configurationPath build-system/fork-development-configuration.json \
 --codesigningInformationPath build-system/fake-codesigning \
 --target //submodules/ShareController:ShareControllerTests
```

It covers caption/entity preservation, source-album grouping, the ten-item chunking of
`groupIntoAlbum`, the single-item grouping-key demotion, where the comment lands with
`removeCaptions`, the forward fallback for uncopyable media, and what
`fastForwardGroupableCount` counts (which decides whether the grouping option is offered).

The test bundle has to ask for `MediaPlayer.framework` itself (`linkopts` on
`ShareControllerTestsLib`): `ShareController` pulls in LegacyComponents, whose `MPVolumeView`
reference the app target satisfies but a bare test bundle does not.

## Media from a link preview

Android's second, unrelated feature also called "Fast Forward" (`PhotoViewer.gallery_menu_fast_fwd`)
extracts the photo/video out of a webpage preview so it can be sent as plain media rather than as
the link. **iOS already does this** without any fork code: `ChatItemGalleryFooterContentNode`
builds `.media(.webPage(webPage:media:))` for webpage content, which has no
`forwardSourceMessageId` and therefore always enqueues a copy. The only thing Android adds on top
is bundling *all* Instant View page photos into one share; that is not ported.

## Assets and strings

Both icons come from Forkgram's `ic_ab_forward_anonym` (the 72 px xxhdpi master), at 24 pt for the
context menu and 30 pt for the selection panel. The surrounding icons are vector PDFs; these are
PNG because the source is raster. They render as templates, so only the alpha channel matters.

**The glyph is not used at its native scale.** Android draws it edge to edge — its ink fills ~93%
of the 24 dp canvas — whereas the stock iOS icons around it fill about 63-74%. Pasted in verbatim
it reads as an oversized button with no padding. So the master is cropped to its ink box, scaled
until its larger dimension is 70% of the target canvas, and re-centred. Re-derive the assets with
that same rule rather than copying the Android PNGs again.

Strings live under the `FastForward.*` prefix in
`Telegram/Telegram-iOS/en.lproj/Localizable.strings`.
