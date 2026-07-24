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

## Follow-up slice: setup and runtime diagnostics

### Acceptance criteria

- [x] Settings reports Accessibility and Screen Recording independently.
- [x] Missing permissions have working request/open-System-Settings actions.
- [x] Settings shows the current completion runtime status without relying on
      the menu-bar menu.
- [x] Permission and model status changes update live while Settings is open.

### TODOs

- [x] Extend the permission model and coordinator with optional Screen
      Recording status and actions.
- [x] Add an observable runtime-status bridge shared by the menu and Settings.
- [x] Add Setup and Models pages to the settings sidebar.
- [x] Run focused and full validation, then record the remaining issue scope.

### Notes

- Screen Recording is reported independently and remains optional while OCR is
  disabled; `nextSettingsPane` continues to represent only required setup.
- `swift test --filter PermissionStateTests` passes (3 tests).
- Permission and model transitions now flow through `RuntimeStatusStore`; the
  existing menu reads the same structured status that Settings will observe.
- Setup reports both permissions with request and System Settings actions.
- Setup also links to Keyboard settings with the exact Text
  Input controls to disable Apple's competing inline predictions and suggested
  replies.
- Models & Providers shows the active runtime plus honest metadata for supported
  local profiles; configuration controls remain deferred until their persistence
  and credential boundaries exist.
- Full `swift test` passes (91 tests).
- Production app build succeeds with the stable Apple Development signature and
  Team ID `VJKBGC9AMK`.
- Remaining issue scope is now primarily provider/model configuration and
  download management, Keychain-backed secrets, launch-at-login/general
  behavior, OCR capture/privacy, shortcuts, and diagnostics export.

## Follow-up slice: configurable providers

### Acceptance criteria

- [x] Provider selection and non-secret configuration persist locally.
- [x] API keys are stored only in Keychain and are never encoded with settings.
- [x] Local, demo, and OpenAI-compatible providers can be selected without
      relaunching StenoTab.
- [x] A remote endpoint can be validated from Settings with useful status.
- [x] Settings can add, edit, select, and remove remote providers.

### TODOs

- [x] Add a secret-free provider settings schema with validation and tests.
- [x] Add a Keychain-backed credential vault.
- [x] Add a live provider controller that applies persisted selections.
- [x] Add provider editing, selection, and connection testing to Settings.
- [x] Run the full suite and signed production build.

### Notes

- Provider settings support built-in demo, local llama.cpp, and stable-ID
  OpenAI-compatible endpoints. The encoded schema has no credential field.
- Remote URLs require HTTP(S) plus a host; completion length is bounded to
  1...32 words.
- `swift test --filter ProviderSettingsTests` passes (4 tests).
- Provider credentials use device-local generic-password Keychain items under
  service `cx.mia.stenotab.providers`, keyed by stable provider ID.
- Keychain create/update/read/delete paths compile in the app target; no
  credential value is logged or copied into the Codable settings document.
- `ProviderSettingsStore` persists non-secret state, migrates the existing
  `local-model.json`, and applies demo/local/remote selections through the
  existing switching provider without relaunching.
- Changing provider cancels and releases any StenoTab-owned llama-server before
  applying the next runtime.
- Models & Providers can select demo/local/remote runtimes, add and edit remote
  endpoint/model/API style/length, save the API key to Keychain, test `/models`,
  and remove both provider metadata and its credential with confirmation.
- `swift test --filter ProviderSettingsTests` passes (5 tests).
- Full `swift test` passes (96 tests).
- Production app build succeeds with stable Apple Development signing and Team
  ID `VJKBGC9AMK`.

## Follow-up slice: context and privacy controls

### Acceptance criteria

- [x] Settings has a dedicated Context & Privacy destination.
- [x] Clipboard context remains opt-in and immediately updates the live prompt
      configuration.
- [x] Unimplemented screenshot/OCR and website sources are visibly unavailable
      rather than presenting controls that silently do nothing.
- [x] The page explains local processing, ephemeral request context, and secure
      field exclusion.

### Notes

- Clipboard requests remain bounded to 2,000 characters by prompt composition
  and are not written into StenoTab history.
- The currently exposed provider is Local, so enabled context remains on the
  Mac. Remote-provider disclosure can be added before that UI is re-exposed.

## Follow-up slice: focused local model setup

### Acceptance criteria

- [x] Setup includes launch-at-login alongside external macOS setup.
- [x] Models presents a disabled provider picker fixed to Local.
- [x] Models explains the llama.cpp runtime and shared Hugging Face cache and
      can open that cache in Finder.
- [x] The model picker combines recommendations and arbitrary cached GGUFs.
- [x] Other accepts a Hugging Face repository ID or URL and downloads a
      preferred single-file GGUF into the shared cache.
- [x] Existing provider settings decode safely and custom/cached profiles
      persist across launches.

### Notes

- Remote-provider configuration and Keychain support remain implemented behind
  the UI, but the current provider surface intentionally exposes Local only.
- Cached model discovery runs off the main actor and deduplicates recommended
  profiles that are already downloaded.
- Custom repositories prefer Q4_K_M and reject sharded-only GGUF repositories
  until multi-file loading is deliberately supported.
- Focused model selection, cache discovery, legacy decoding, repository input,
  and cache-layout tests pass (13 tests).
- Full `swift test` passes (105 tests).
- Production app build succeeds with stable Apple Development signing and Team
  ID `VJKBGC9AMK`.

## Follow-up slice: local model management

### Acceptance criteria

- [x] Settings edits local profile, server URL, and completion length.
- [x] Cache state uses the standard Hugging Face cache root and can be revealed.
- [x] Missing supported models can be downloaded into a valid Hugging Face
      snapshot/blob/ref layout with visible progress.
- [x] Selecting a downloaded local model starts or reuses llama.cpp immediately.
- [x] Download failures leave no model that appears complete.

### TODOs

- [x] Add local model configuration and shared-cache inspection controls.
- [x] Add a Hugging Face cache download planner with layout tests.
- [x] Add resumable download execution and progress to the provider store/UI.
- [x] Run full tests and a signed production build.

### Notes

- Local settings now edit the selected profile, dedicated server URL, and
  completion length; choosing local applies immediately through the provider
  controller.
- The UI resolves the same standard Hugging Face cache path used at runtime,
  reveals downloaded files in Finder, and downloads missing profiles in-app.
- The download planner produces the standard repository `blobs/`,
  `snapshots/<revision>/`, and `refs/main` paths and rejects traversal in
  server-supplied revision/ETag identifiers.
- `swift test --filter HuggingFaceDownloadPlanTests` passes (2 tests).
- The in-app downloader resumes partial files, publishes a snapshot only after
  exact byte completion, reports progress, and selects the local runtime after
  a successful install.
- `swift test --filter HuggingFaceDownloadPlanTests` passes (3 tests).
- Full `swift test` passes (99 tests).
- Production app build succeeds with stable Apple Development signing and Team
  ID `VJKBGC9AMK`.

## Follow-up slice: general and acceptance behavior

### Acceptance criteria

- [ ] Global completion enablement has one persistent source of truth shared by
      Settings, the menu-bar menu, and request gating.
- [ ] Menu-bar icon visibility persists and changes immediately; reopening the
      already-running app still provides a route back to Settings.
- [ ] Tab continues to accept one word and Option-Tab accepts the full
      suggestion.
- [ ] The user can choose whether single-word acceptance includes generated
      trailing space and attached punctuation.
- [ ] Settings includes dedicated General and Shortcuts destinations using the
      same live state as runtime behavior.

### TODOs

- [x] Add pure persisted general/acceptance settings and configurable
      single-word slicing tests.
- [ ] Wire one live settings store through global gating, menu visibility, and
      suggestion acceptance.
- [ ] Add General and Shortcuts settings pages.
- [ ] Run focused/full tests and a signed production build.

### Notes

- Defaults preserve the existing behavior: Tab accepts one word, Option-Tab
  accepts everything, attached punctuation is included, and trailing spaces
  remain in the unaccepted suggestion.
- `swift test --filter 'SuggestionAcceptanceTests|GeneralSettingsTests'`
  passes (8 tests).
