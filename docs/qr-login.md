# Log in by QR code

Port of item 8.6 in [`forkgram-port-roadmap.md`](forkgram-port-roadmap.md)
(Android commit `cf5cfab876`): the login screen shows a QR code that is scanned
with an **already authorized** client. This mirrors the stock "Link Desktop
Device" flow — there the phone scans a desktop's code, here the phone shows one.

## What already existed on iOS, and why it did not work

All of the protocol machinery was in place.
`TelegramEngineUnauthorized.auth.exportAuthTransferToken` in
`submodules/TelegramCore/Sources/TelegramEngine/Auth/AuthTransfer.swift` handles
`auth.exportLoginToken`, migration to another datacenter through
`auth.importLoginToken`, `SESSION_PASSWORD_NEEDED`, and writing the resulting
authorization.

Its only consumer, though, was a debug stub in
`AuthorizationSequencePhoneEntryControllerNode`:

- the gesture that opened it sat behind `#if DEBUG && false`, so it never
  compiled at all;
- it drew a bare 200×200 `ASImageNode` with no title, hints or buttons;
- `case .loggedIn, .passwordRequested:` only cleared a disposable, so **login
  never completed**.

That is why the roadmap wrongly marked the item as already shipped on iOS.

## What was added

| File | Role |
|---|---|
| `submodules/AuthorizationUI/Sources/AuthorizationSequenceQrLoginController.swift` | Screen: token refresh loop and result handling |
| `submodules/AuthorizationUI/Sources/AuthorizationSequenceQrLoginControllerNode.swift` | Layout: title, subtitle, code, three steps, phone fallback button |
| `AuthorizationSequencePhoneEntryController{,Node}.swift` | "Log in by QR Code" button under the continue button |
| `AuthorizationSequenceController.swift` | `pushQrLoginController()` |

The `QrCode` module was already a dependency of `AuthorizationUI`, so no BUILD
changes were needed.

## Invariants

- **Completing the login is not handled by the screen.**
  `exportAuthTransferToken` writes the result into the account itself: it calls
  `switchToAuthorizedAccount` on success and sets `.passwordEntry` for 2FA.
  `AuthorizationSequenceController.updateState` observes that state and shows the
  password screen or finishes authorization. The screen only forwards
  `accountUpdated` when the token moved the account to another datacenter
  (`.changeAccountAndRetry`).
- **The debug stub in the phone entry screen was removed, not left beside it.**
  Its `updateLoginTokenEvents` subscription was live (unlike the gesture) and
  exported tokens into nowhere; two concurrent exports would have raced the new
  screen for the token.
- **`updateLoginTokenEvents` is the primary signal, the timer only a fallback.**
  The server pushes `updateLoginToken` the moment the other device confirms, so
  the next export returns the authorization instead of waiting for `validUntil`
  to expire.
- **`otherAccountUserIds` is filtered by `testingEnvironment`.** Production and
  test-backend ids must not be mixed: the server uses them to refuse re-adding an
  account that is already signed in here.
- **The code is drawn black on white regardless of theme**, on a white card: a
  theme-tinted code is unreliable for scanners. The icon is `.none`, because
  `.cutout` leaves an empty hole in the middle that a logo has to be drawn over
  separately.
- **Link format** is `tg://login?token=<base64url>`: base64 with `+` replaced by
  `-` and `/` by `_`.

## Not done

- Telegram logo in the middle of the code (needs `.cutout` plus a separate node
  drawn on top).
- The entry point exists only on the phone entry screen; there is no button on
  the splash screen.

## Verification status

Checked by hand on device: the screen renders and shows a live token, which means
`exportAuthTransferToken` really did round-trip against the server. Not checked:
completing a login end to end, the 2FA path, and datacenter migration.
