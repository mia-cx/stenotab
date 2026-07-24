# StenoTab

> Experimental macOS prototype. The name, UX, and model integrations are intentionally unfinished.

Low-latency, system-wide text completion for macOS. Type in an editable field,
see translucent inline ghost text at the caret, press Tab to accept the next
word, or press Option+Tab to accept the entire suggestion. The renderer uses
the editor's Accessibility-exposed font, size, and foreground colour when
available.

## Try it

Requirements: macOS 14 or later and Swift 6.2 or later. A full Xcode install is recommended; the package can be opened directly in Xcode.

```sh
./Scripts/build-and-run.sh
```

Grant the resulting app Accessibility access when macOS asks. Input Monitoring
is not required. Then type `thank`, `looking forward`, or `let me know` in an
editable field to exercise the built-in zero-dependency demo provider.

The app lives in the menu bar. Quit or disable completions there.

## Tests

The behavior suite uses XCTest and can run from Xcode, including Xcode beta.
From the shell, `swift test` uses the currently selected developer toolchain.
If `xcode-select -p` reports `/Library/Developer/CommandLineTools`, either run
the package's tests in Xcode or select an Xcode installation whose command-line
components are available.

## Use an OpenAI-compatible model

The default provider is deliberately deterministic so the interaction loop can be tested without downloading a model. Set these variables before launching to use any server implementing `POST /v1/chat/completions`:

```sh
export STENOTAB_BASE_URL=http://127.0.0.1:8080
export STENOTAB_MODEL=your-model-name
export STENOTAB_API_KEY=optional
./Scripts/build-and-run.sh
```

Only the API provider sends text outside the Mac. Secure text fields are rejected. The prototype sends up to 1,500 characters before the cursor and 300 after it.

## Use the local llama.cpp model

StenoTab's recommended local backend is Gemma 4 E2B Base Q4_K_M on llama.cpp.
Model weights remain in the standard Hugging Face cache
(`~/.cache/huggingface`); StenoTab never copies them into its bundle or
Application Support.

```sh
# Requirements for the current development build.
brew install hf llama.cpp

# See the configured local profile without downloading anything.
./Scripts/local-model.zsh list

# Download into the shared Hugging Face cache and configure StenoTab.
./Scripts/local-model.zsh configure gemma-4-e2b-base

# Restart StenoTab. It launches, monitors, and shuts down llama-server.
# Once the menu says the local model is ready, benchmark it if desired.
./Scripts/local-model.zsh benchmark gemma-4-e2b-base

# Inspect or render the reusable OCR/clipboard/user-voice fixture suite.
./Scripts/benchmark-local-model.py --list-cases
```

On a 10-core M4 MacBook Air with 16 GB unified memory, direct llama.cpp
measured 80 ms median and 100 ms p95 cached-input TTFT across the autocomplete
fixtures. A warmed fixed-length probe measured 69 ms TTFT and 50.5 tok/s.
These are development snapshots, not hardware-independent promises.

StenoTab uses the Base model for continuation because an IT model interprets an
unfinished model turn as assistant text and can slip into phrases such as
“I can help.” A separate short lexical prompt handles words the macOS spell
checker identifies as unfinished; ordinary complete words stay on the
contextual continuation path.

At launch, StenoTab checks the configured endpoint's `/v1/models`. It reuses an
existing server only when that server advertises the selected model, including
multi-model llama.cpp router servers. Otherwise StenoTab starts its own
localhost-only server on its dedicated default port, `18473`, or the next
available port. `STENOTAB_LOCAL_PORT` overrides that default. On quit,
StenoTab terminates only a server process it launched itself.

`max_tokens` primarily limits generation and KV-cache growth. It does not avoid
loading the model weights.

### Visual context strategy

The low-latency path should prefer Accessibility text, then cached local Vision
OCR. OCR should refresh when focus, window contents, or conversation context
changes—not on every keystroke. A multimodal screenshot request remains useful
as an optional fallback when layout or non-text visual state materially changes
the intended reply, but repeatedly encoding screenshots would substantially
increase TTFT.

## Why this should feel faster than KeyType

The latency-sensitive path does not ask Accessibility for the entire editor state after every keystroke:

1. A Core Graphics event tap updates an in-memory shadow text buffer immediately.
2. A real 45 ms quiet-period debounce happens **before** inference starts.
3. One worker performs model requests. While it is busy, pending work is replaced by the newest request.
4. Stale results are discarded by request ID.
5. Accessibility seeds and periodically reconciles context, identifies secure fields, and locates the caret.
6. There are no synchronous telemetry writes in the typing path.

This directly targets the likely KeyType failure mode: repeatedly launching work, cancelling tasks that cannot interrupt synchronous inference, and then queueing fresh work behind obsolete inference.

## Prototype boundaries

- The built-in provider proves the global interaction loop, not completion quality.
- OpenAI-compatible HTTP and StenoTab-managed llama.cpp work now. Persistent ACP sessions for Codex/Claude belong behind the same provider boundary but are not implemented yet.
- Tab acceptance uses a short-lived pasteboard swap because that works in more apps than direct AX replacement.
- Some custom editors expose incomplete Accessibility text or caret information.
- The app is ad-hoc signed and not notarized.
- Multi-display caret-coordinate handling is only a first pass.

## Project layout

- `CompletionCore`: shadow text buffer and latest-request-only scheduler.
- `StenoTab`: menu-bar app, event tap, Accessibility reader, provider, overlay, and acceptance.
- `CompletionCoreTests`: focused XCTest behavior tests.

## Next slices

1. Add latency instrumentation with buffered, off-hot-path persistence.
2. Add interruptible decoding and explicit memory-pressure controls to the managed llama.cpp runtime.
3. Bundle and sign llama.cpp for release builds instead of relying on Homebrew.
4. Add persistent ACP clients for Codex and Claude rather than spawning a CLI process per completion.
5. Learn per-app editor quirks and add a compatibility matrix.

The proposed privacy-local learning architecture is documented in
[`docs/LOCAL_VOCABULARY.md`](docs/LOCAL_VOCABULARY.md).

The exploratory StenoTalk and cross-platform direction is documented in
[`docs/CROSS_PLATFORM_ARCHITECTURE.md`](docs/CROSS_PLATFORM_ARCHITECTURE.md).
