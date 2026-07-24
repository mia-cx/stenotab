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

- [ ] App policy is keyed by bundle identifier, with global-default inheritance
      and explicit enabled/disabled overrides.
- [ ] Seen non-secure apps persist with display name, bundle identifier, icon
      location when available, and last-seen timestamp.
- [ ] Secure fields are never added to the seen-app registry.
- [ ] Disabled app policy is checked before completion scheduling, context
      collection, or inference.
- [ ] The menu bar can enable or disable StenoTab for the focused app and updates
      its title/state as focus changes.
- [ ] Settings contains a searchable App Settings page whose changes are
      immediately effective.
- [ ] Core policy, persistence payloads, and secure-field exclusion have
      automated tests.

## TODOs

- [x] Add pure, Codable app-policy and seen-app domain models with tests.
- [x] Add a persistent application-policy store and app-observation boundary.
- [x] Enforce app policy before completion/context work and test the gating rule.
- [ ] Add the focused-app menu toggle with live state.
- [ ] Add a searchable App Settings page backed by the same live store.
- [ ] Run the full test suite and signed production build; document residual
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
