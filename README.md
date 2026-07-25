# StenoTab

**Bring your model. Press Tab.**

StenoTab is an experimental, system-wide AI autocomplete app for macOS. It
places translucent completion text at the caret in supported native editors
and tested web-backed apps, currently including Chrome, Arc, Discord, Slack,
ChatGPT, and Codex. Accessibility support varies by editor.

Press **Tab** to accept the next word or **Option–Tab** to accept the entire
suggestion. StenoTab is designed around short, low-latency continuations that
sound like the person typing—not an assistant answering them.

> [!WARNING]
> StenoTab is a public alpha. It is under active development, has no packaged
> release or notarized distribution build yet, and currently has no license
> file. Expect rough edges and breaking changes.

## What works today

- System-wide inline ghost text in supported native macOS editors and tested
  web-backed apps.
- Accessibility-based focused-field detection, text context, caret geometry,
  typography estimation, and secure-field exclusion.
- A low-latency shadow text buffer with a 45 ms debounce, latest-request-only
  scheduling, and stale-response rejection.
- No inference for inputs with fewer than three non-whitespace characters.
- Suggestions remain alive while the user types matching predicted text.
- Local completions stream into the inline overlay token by token. Matching
  typing and Tab acceptance advance through the same in-flight response;
  StenoTab cancels only when the edit diverges or a newer request supersedes it.
- **Tab** accepts one word at a time; **Option–Tab** accepts everything.
- Suggestions reanchor after accepted text and across line wrapping.
- Screenshot keyboard shortcuts do not dismiss an active suggestion.
- A menu-bar app with a daily accepted-suggestion counter.
- Setup, Models, Context & Privacy, Prompt Lab, and App Settings pages.
- Per-app enable/disable overrides and a quick toggle for the focused app.
- Launch at login.
- Opt-in focused-window screenshots with local Vision OCR. Captures run when
  focus enters an editor and, when the cached context is stale, at the start of
  a new typing burst.
- Local GGUF inference through a StenoTab-managed `llama-server`.
- Model discovery and downloads in the shared Hugging Face cache.
- Editable, modular Markdown prompt components and a live composed preview.
- Encrypted, local writing history with full-field/cursor snapshots for
  accepted suggestions and completed writing episodes.
- Personal vocabulary, preferred capitalization, one-to-five-token phrase
  learning, recency decay, per-app/input-kind ranking, and negative feedback
  from immediately reverted suggestions.
- High-confidence local phrase completion that can avoid model inference.
- Frecent writing examples and opt-in semantically relevant examples, using
  encrypted Apple Natural Language embeddings generated off the keystroke
  path.
- Periodic, inspectable voice summaries based on observable local writing
  traits.
- Personalization controls for retention, encrypted storage limits,
  inspection, export, per-record/per-app deletion, and delete-all.
- OpenAI-compatible provider support in the core and through developer
  configuration.

## Requirements

- macOS 26 or later.
- A Mac supported by macOS 26. Apple silicon is the current development and
  performance target.
- Full Xcode with the macOS 26 SDK or later. The package uses Swift tools 6.2.
- [`llama.cpp`](https://github.com/ggml-org/llama.cpp) when using local
  inference. During development, `brew install llama.cpp` provides
  `llama-server`.

StenoTab currently builds a native app for the architecture of the development
Mac. Universal release packaging has not been implemented.

## Build and run

```sh
brew install llama.cpp
git clone https://github.com/mia-cx/stenotab.git
cd stenotab
./Scripts/build-and-run.sh
```

The script builds a release binary, compiles the Icon Composer artwork,
assembles `.build/StenoTab.app`, signs it with the first available Apple
Development identity, and launches it. Set `STENOTAB_NO_OPEN=1` to build
without launching.

To use Launch at Login, copy `StenoTab.app` to `/Applications`; registration is
unavailable while running the app from `.build`.

If no Apple Development identity is available, the script falls back to ad-hoc
signing. Ad-hoc signatures change between builds and can cause macOS to forget
Accessibility consent. A stable signing identity is strongly recommended:

```sh
STENOTAB_SIGNING_IDENTITY="Apple Development: you@example.com (TEAMID)" \
  ./Scripts/build-and-run.sh
```

## First-run setup

Open **StenoTab → Settings** from the menu-bar item.

1. In **Setup**, grant Accessibility permission. StenoTab cannot locate text
   fields, render at the caret, or insert accepted text without it.
2. Screen Recording is optional. Grant it only if you want to enable local
   screenshot/OCR context in **Context & Privacy**.
3. If Setup reports that macOS inline predictive text or suggested replies are
   enabled, click **Turn Off**. The row turns green when both competing
   suggestion features are disabled.
4. In **Models**, download the recommended model or select a compatible GGUF
   already present in the Hugging Face cache.
5. Type at least three non-whitespace characters in a non-secure editor and
   pause briefly.

Input Monitoring permission is not required.

## Local models

The recommended model is:

- **Gemma 4 E2B Base Q4_K_M**
- Hugging Face repository:
  [`mradermacher/gemma-4-E2B-GGUF`](https://huggingface.co/mradermacher/gemma-4-E2B-GGUF)
- File: `gemma-4-E2B.Q4_K_M.gguf`
- Recommended minimum: 16 GB unified memory

The base model is intentional. For completion, StenoTab treats the model as the
person doing the writing and ends the prompt on the literal text at the cursor.
Instruction-tuned variants were more likely to answer as an assistant or leak
prompt framing.

The Models page can download a recommended model or a custom Hugging Face
repository directly into the standard shared cache. StenoTab does not create a
second private copy of model weights.

At startup, StenoTab probes the configured `/v1/models` endpoint. It reuses a
compatible server, searches the next 20 ports when the endpoint responds with
an incompatible model, and otherwise attempts to start its managed server at
the configured port. On quit, StenoTab stops only a server process it launched
itself.

The default endpoint is `http://127.0.0.1:18473/v1`. StenoTab consumes the
OpenAI-compatible server-sent event stream so the first usable completion
fragment can appear before generation finishes. The managed server uses a
4,096-token context, prompt caching, flash attention, and one parallel request.
Its log is stored at:

```text
~/Library/Application Support/StenoTab/llama-server.log
```

The helper script remains useful for development:

```sh
./Scripts/local-model.zsh list
./Scripts/local-model.zsh configure gemma-4-e2b-base
./Scripts/local-model.zsh benchmark gemma-4-e2b-base
```

`configure` writes the legacy bootstrap configuration used only when no
persisted Models settings exist. Existing installations should select the model
in **Settings → Models**.

## Prompt and context model

StenoTab’s prompt is composed from individually editable Markdown resources in
[`Sources/CompletionCore/Resources/Prompts`](Sources/CompletionCore/Resources/Prompts).
The Settings window exposes the same composition through Prompt Lab, including
a complete base-model and chat-API preview.

Current context support:

| Context source | Status | Default |
| --- | --- | --- |
| Current application | Working | On |
| Input kind inferred from Accessibility | Working | On |
| Text before and after the cursor | Working | Always |
| Clipboard text, up to 2,000 characters | Working | Off |
| Bundled seed writing examples | Working fallback | On |
| Current website | Not connected | Off |
| Focused-window screenshot and local OCR | Working | Off |
| Frecent writing examples | Working from encrypted local history | On |
| Semantically relevant examples | Working with local encrypted embeddings | Off |
| Periodic voice assessment | Working from local history | Off |
| Custom voice instructions | Working | Empty |

[`docs/PROMPT_DRAFT.md`](docs/PROMPT_DRAFT.md) contains a full human-editable
sample with data for every planned component.

## Privacy

- Secure and password fields are excluded.
- With the default `127.0.0.1` Server URL, local-model completion requests stay
  on the Mac. Changing that URL can send enabled context to another host.
- Reading clipboard text for prompt context is opt-in, limited to 2,000
  characters, assembled in memory, and not retained.
- Screenshot/OCR context is opt-in and requires Screen Recording permission.
  StenoTab captures only the focused app window—not the full display—when focus
  enters an editor. A new typing burst refreshes the capture only when the
  cached result is stale. Vision recognizes the text locally, the screenshot is
  discarded immediately, and up to 6,000 characters of normalized OCR text are
  retained in memory for the current editor.
- Suggestion acceptance posts literal Unicode keyboard events; it does not
  paste clipboard content or replace the pasteboard.
- Personalization collection is enabled by default and can be disabled in
  **Settings → Personalization**. Canonical full-field events, scope values,
  derived language models, embeddings, and voice assessments are encrypted at
  rest with a Keychain-backed key. Only HMAC lookup keys, event kinds,
  timestamps, vector dimensions, and model identifiers remain queryable
  metadata.
- Personalization work runs in a background actor. Key callbacks only update
  the in-memory shadow buffer and schedule work.
- Export is an explicit user action and produces readable JSON at the selected
  destination.
- Current-website detection remains unavailable, so website-scoped learning is
  represented in the schema but not populated yet.
- Remote OpenAI-compatible providers can send enabled context off-device; that
  path is intended for explicit developer configuration and is not the exposed
  default in this alpha.

## Developer provider override

Developers can bypass the persisted local selection with an
OpenAI-compatible endpoint:

```sh
export STENOTAB_BASE_URL=http://127.0.0.1:8080
export STENOTAB_MODEL=your-model-name
export STENOTAB_API_KEY=optional
export STENOTAB_API_STYLE=textCompletions
export STENOTAB_MAXIMUM_WORDS=8
./Scripts/build-and-run.sh
```

`STENOTAB_API_STYLE` accepts `textCompletions`, `chatCompletions`, or
`gemmaChatPrefill`.

## Architecture

```text
Global event tap
    ↓
ShadowTextBuffer + Accessibility reconciliation
    ↓
latest-request-only completion scheduler
    ↓
prompt composition → provider → sanitizer
    ↓
nonactivating inline overlay
    ↓
Tab acceptance + caret reanchoring
```

- `CompletionCore` contains platform-light prompt, scheduling, policy,
  sanitization, acceptance, geometry, retrieval, vocabulary/n-gram learning,
  and voice-analysis logic.
- `StenoTabPersistence` owns the encrypted SQLite event ledger, encrypted
  projections, embedding rows, retention, export, and deletion operations.
- `StenoTab` contains the AppKit/SwiftUI shell, global event tap,
  Accessibility reader, overlay, provider runtime, Settings, and menu bar.
- `CompletionCoreTests` contains the deterministic behavior suite.
- `Benchmarks` contains reusable context-rich completion fixtures and local
  latency tools.

The cross-platform boundary and possible future StenoTalk direction are
documented in
[`docs/CROSS_PLATFORM_ARCHITECTURE.md`](docs/CROSS_PLATFORM_ARCHITECTURE.md).

## Tests

```sh
swift test
```

The suite covers prompt composition, partial-word handling, completion
sanitization, request coalescing, exact-match consumption, word-by-word
acceptance, streamed-response cancellation and overlap tracking, refill
behavior, per-app policy, model selection, permission state, caret geometry,
and typography calibration, plus encrypted personalization persistence,
full-field history, feedback capture, vocabulary/n-gram ranking, retrieval,
Unicode-safe deletion, and voice assessment.

Run the deterministic personalization latency benchmark in release mode:

```sh
swift run -c release PersonalizationBenchmark
```

The benchmark covers warmed local completion, Apple Natural Language query
embedding, frecent top-five retrieval over 10,000 examples, and cosine
retrieval over 2,000 512-dimensional vectors. Baselines and acceptance budgets
are documented in [`Benchmarks/README.md`](Benchmarks/README.md).

Benchmark fixtures can be inspected with:

```sh
./Scripts/benchmark-local-model.py --list-cases
```

## Known limitations

- No downloadable, notarized GitHub release yet.
- `llama-server` is discovered from the app bundle, `PATH`, or common Homebrew
  locations; it is not bundled by the current build script.
- Completion quality and prompt wording are still being tuned.
- Accessibility quality varies between editors and frameworks.
- Website detection is unfinished, so website-scoped personalization is not
  populated.
- Semantic retrieval currently embeds accepted-suggestion inputs; directly
  typed examples participate in frecent retrieval but not the semantic index.
- Persistent ACP sessions for installed Codex and Claude are planned, not
  implemented.
- Provider selection in the current Settings UI is intentionally locked to
  Local while the product path is stabilized.

Design notes for local personalization live in
[`docs/LOCAL_HISTORY_RETRIEVAL.md`](docs/LOCAL_HISTORY_RETRIEVAL.md) and
[`docs/LOCAL_VOCABULARY.md`](docs/LOCAL_VOCABULARY.md). Exact model inputs,
streamed suggestions, acceptance/rejection outcomes, and resulting editor text
are described in
[`docs/COMPLETION_EPISODES.md`](docs/COMPLETION_EPISODES.md).

## Contributing

The repository is public so the implementation and design can be inspected and
discussed early. A contribution guide, code of conduct, issue templates, and
license still need to be selected. Until then, please use
[GitHub Issues](https://github.com/mia-cx/stenotab/issues) for bugs and design
discussion before investing in a large change.
