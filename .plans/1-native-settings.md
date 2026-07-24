# #1 Add native settings window and per-app controls

## Summary

Turn the existing Prompt Lab window into the beginning of StenoTab's native
settings app, starting with a complete per-app enablement slice. StenoTab should
remember non-secure apps it sees, let the user override completion policy by
bundle identifier, enforce that policy before context capture or inference, and
surface the same state in both the menu bar and Settings.

This branch intentionally leaves provider credentials, model management, OCR,
launch-at-login, and shortcut editing for later slices of the broad issue.

## Acceptance criteria

- [x] App policy is keyed by bundle identifier, with global-default inheritance
      and explicit enabled/disabled overrides.
- [x] Seen non-secure apps persist with display name, bundle identifier, icon
      location when available, and last-seen timestamp.
- [x] Secure fields are never added to the seen-app registry.
- [x] Disabled app policy is checked before completion scheduling, context
      collection, or inference.
- [x] The menu bar can enable or disable StenoTab for the focused app and updates
      its title/state as focus changes.
- [x] Settings contains a searchable App Settings page whose changes are
      immediately effective.
- [x] Core policy, persistence payloads, and secure-field exclusion have
      automated tests.

## TODOs

- [x] Add pure, Codable app-policy and seen-app domain models with tests.
- [x] Add a persistent application-policy store and app-observation boundary.
- [x] Enforce app policy before completion/context work and test the gating rule.
- [x] Add the focused-app menu toggle with live state.
- [x] Add a searchable App Settings page backed by the same live store.
- [x] Run the full test suite and signed production build; document residual
      issue scope.

## Notes

- Branch: `issue/1-native-settings`
- Worktree: `.worktrees/1-native-settings`
- Base: local `main` at `68e27a9`, including the verified Prompt Lab slice.
- Existing Prompt Lab settings remain in `UserDefaults`; provider secrets will
  require Keychain in a later slice.
- `swift test --filter ApplicationPolicyTests` passes (5 tests).
- App target compiles after wiring `ApplicationPolicyStore`; observations are
  emitted only from successful non-secure editor snapshots and persistence is
  throttled to at most once per app per minute when metadata is unchanged.
- Policy is checked from the frontmost bundle identifier before taking an AX
  editor snapshot, building clipboard context, dispatching a request, accepting
  a suggestion, or delivering a queued response.
- `swift test --filter ApplicationPolicyTests` passes (6 tests).
- The status menu recomputes the frontmost app whenever it opens, persists an
  explicit enable/disable override, and tells the coordinator to cancel or
  resume work immediately.
- `swift test --filter ApplicationPolicyTests` passes (7 tests).
- Settings now has an App Settings destination with global-default control,
  bundle/name search, native app icons, last-seen metadata, and per-app
  inherit/enabled/disabled selection.
- Store mutations notify the coordinator through one shared callback, so both
  Settings and menu changes are immediately effective.
- Full `swift test` passes (90 tests).
- Production `Scripts/build-and-run.sh` build succeeds and is signed by
  `Apple Development: mia@mia.cx (KMCJ596S53)` with Team ID `VJKBGC9AMK`.
- Issue #1 remains open. Deferred scope includes setup/permission UI, launch at
  login, provider/model configuration, Keychain credentials, OCR privacy
  controls, shortcuts, diagnostics, and general settings beyond app policy.
