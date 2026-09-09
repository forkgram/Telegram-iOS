# Hidden accounts

Port of `ID_HIDDEN_ACCOUNTS` / `HiddenAccountHelper` from Forkgram (Android).
Item 2.4 in [`forkgram-port-roadmap.md`](forkgram-port-roadmap.md).

A hidden account **keeps running in full** — it holds its connection, syncs and
receives messages. It is only excluded from every account listing in the UI and
posts no notifications until it is unlocked with its own code. The unlocked
state lives in memory only: the account is hidden again as soon as the user
switches away from it, locks the app or leaves it.

## Where things live

| Layer | File |
|---|---|
| Storage (shared data) | `submodules/TelegramUIPreferences/Sources/HiddenAccountsSettings.swift` |
| Code hashing | `submodules/HiddenAccounts/Sources/HiddenAccountCode.swift` |
| Runtime state | `submodules/HiddenAccounts/Sources/HiddenAccountsManager.swift` |
| Owner of the manager | `submodules/AppLock/Sources/AppLock.swift` |
| Unlock on the lock screen | `submodules/PasscodeUI/Sources/PasscodeEntryController.swift` |
| Unlock through search | `submodules/ChatListUI/Sources/ChatListSearchContainerNode.swift` |
| Filtering + auto-switching | `submodules/TelegramUI/Sources/SharedAccountContext.swift` |
| Account list filtering | `submodules/AccountUtils/Sources/AccountUtils.swift` |
| Management screen | `submodules/SettingsUI/Sources/Privacy and Security/HiddenAccountsController.swift` |
| Push suppression | `Telegram/NotificationService/Sources/NotificationService.swift` |
| Tests | `submodules/HiddenAccounts/Tests/HiddenAccountCodeTests.swift` |

## Why the manager hangs off `AppLockContext`

`HiddenAccountsManager` is reached as `sharedContext.appLockContext.hiddenAccounts`.
That is the only object visible to **both** unlock surfaces: `PasscodeEntryController`
has no `AccountContext` (it is created by `AppLockContextImpl` with just an
`accountManager`), and the regular UI has no direct reference to the app lock. So
`hiddenAccounts` is declared on the `AppLockContext` protocol (in
`submodules/AccountContext`), and `HiddenAccounts` itself is a leaf module that
`AccountContext` depends on.

`HiddenAccounts` depends on `TelegramUIPreferences` (which holds
`HiddenAccountsSettings`) but not the other way round, so there is no cycle:
`TelegramUIPreferences` knows nothing about `AccountContext`.

## How the code is stored

The code is **never stored** — only `SHA-256(salt ‖ code ‖ salt)` and the salt
itself (16 bytes from `SecRandomCopyBytes`), in `HiddenAccountEntry`. The salt is
repeated on both sides so that the tiny numeric code space cannot be attacked
with a single precomputed table shared across accounts. Comparison is constant
time.

Entries live in the account manager's shared data
(`ApplicationSpecificSharedDataKeys.hiddenAccountsSettings`) rather than in a
specific account's postbox: they have to be readable while the app is locked and
from the notification service extension.

## Invariants the compiler will not check

- **The shape of the code is dictated by the passcode entry field, and there are
  three of them.** `PasscodeInputFieldNode` auto-submits at exactly 4 or 6
  characters for `.digits4` / `.digits6`, while `.alphanumeric` submits on return
  and accepts anything. So a hidden account's code has to match the app passcode
  in shape, or it could not physically be typed on the lock screen.
  `HiddenAccountsManager.requiredCodeType` derives `HiddenAccountCodeType`
  (`.digits4` / `.digits6` / `.alphanumeric`) from `PostboxAccessChallengeData`.
- **Without an app passcode the code is forced to be numeric.** Unlocking then
  goes through chat list search, where an alphanumeric code cannot be told apart
  from an ordinary query.
- **The shape is recorded in the entry (`codeType`).** If the app passcode later
  changes — from 4 to 6 digits, or to alphanumeric — lookup by code keeps working
  against the *recorded* shape, and the management screen offers a field of the
  matching type. Without this the account would be unreachable forever; the
  screen also warns about such stale codes.
- **Turning the app passcode off force-enables stealth mode** when hidden accounts
  exist (`HiddenAccountsManager.init`). Otherwise both unlock surfaces would
  disappear at once.
- **The screen offers to set up the app passcode itself.** While no passcode is
  set, a "Set App Passcode" row appears and leads into the standard
  `passcodeOptionsAccessController`; the feature's dependency on the passcode is
  otherwise not obvious.
- **The last visible account cannot be hidden** — `reconcileHiddenAccountVisibility`
  would have nowhere to switch to. Checked in `HiddenAccountsController`.
- **Clearing the unlock on the lock screen is edge triggered**, not done on every
  event (`AppLockContextImpl.wasCurrentlyLocked`). `unlock()` queues the account
  *before* the lock state is written (that write is async via
  `Queue.mainQueue().async`), so clearing on every "still locked" emission would
  wipe a pending unlock.
- **Backgrounding is tracked through `applicationInForeground`, not
  `applicationIsActive`.** The latter drops to false for system alerts and the app
  switcher, which would discard the session far too aggressively.
- **`switchToAccount` refuses a locked hidden account.** That closes the paths
  through a notification tap, a deep link and a stale controller.
- **`activeAccountsAndPeers(includeHidden:)`** is `true` only for the management
  screen itself. Every other account listing must leave hidden accounts out.

## How the state converges

`SharedAccountContextImpl.reconcileHiddenAccountVisibility` is the single place
that keeps the primary account consistent with hidden state. It observes
`activeAccountContexts × hiddenAccounts.visibilityUpdated`:

1. If the primary changed — `accountBecamePrimary(id)`: leaving an unlocked hidden
   account re-hides it immediately. Tracked through `hiddenAccountsObservedPrimaryId`
   to tell "the user switched away" from "we have not switched yet".
2. If an account is unlocked and is not the primary — switch to it.
3. If the primary is hidden and not unlocked — switch to the first visible one.

Full pass when launching with a hidden primary: launch → lock screen → step 3
moves to a visible account behind the lock screen → the user enters the hidden
account's code → `unlock()` takes the pending account → step 2 switches back.

## Changes to existing files

`PasscodeSetupController` is reused for entering codes. Added:
- `allowsPasscodeTypeSelection` — hides the "Passcode Options" button, since the
  shape of the code is dictated from outside;
- `titleOverride` — replaces the prompt above the field;
- in `.setup` the node used to **hardcode** `.digits6`, ignoring the type it was
  given; it now honours it. All three existing call sites passed `.digits6`, so
  behaviour is unchanged.

Verifying an existing code uses `.entry(PostboxAccessChallengeData)`: the
challenge is read only to pick the field type, while the real comparison happens
in the `check` closure against the account's own code.

## Not ported

- Excluding hidden accounts from contact synchronisation and share-sheet
  shortcuts (Android: `ContactsController.checkAppAccount`,
  `MediaDataController.buildShortcuts`).
- The Fork settings screen (tier 0 of the roadmap) — the entry point lives in
  Privacy & Security instead.

## Verification status

Unit tests cover code shape derivation, per-type validation, hashing, and that a
change of app passcode shape does not strand an existing hidden account:

```sh
python3 build-system/Make/Make.py --overrideXcodeVersion test \
 --configurationPath build-system/fork-development-configuration.json \
 --codesigningInformationPath build-system/fake-codesigning \
 --target //submodules/HiddenAccounts:HiddenAccountsTests
```

Checked by hand on device: hiding an account, the account listing, and the code
shape shown for a 4-digit app passcode. Not yet checked by hand: the "Set App
Passcode" row and the stale-code warning.
