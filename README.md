# Tab Completions Everywhere

> Experimental macOS prototype. The name, UX, and model integrations are intentionally unfinished.

Low-latency, system-wide text completion for macOS. Type in an editable field, see translucent inline ghost text at the caret, and press Tab to accept it. The renderer uses the editor's Accessibility-exposed font, size, and foreground colour when available.

## Try it

Requirements: macOS 14 or later and Swift 6.2 or later. A full Xcode install is recommended; the package can be opened directly in Xcode.

```sh
./Scripts/build-and-run.sh
```

Grant the resulting app Accessibility access when macOS asks. Input Monitoring
is not required. Then type `thank`, `looking forward`, or `let me know` in an
editable field to exercise the built-in zero-dependency demo provider.

The app lives in the menu bar. Quit or disable completions there.

## Use an OpenAI-compatible model

The default provider is deliberately deterministic so the interaction loop can be tested without downloading a model. Set these variables before launching to use any server implementing `POST /v1/chat/completions`, including a local llama.cpp or MLX-backed server:

```sh
export TAB_COMPLETION_BASE_URL=http://127.0.0.1:8080
export TAB_COMPLETION_MODEL=your-model-name
export TAB_COMPLETION_API_KEY=optional
./Scripts/build-and-run.sh
```

Only the API provider sends text outside the Mac. Secure text fields are rejected. The prototype sends up to 1,500 characters before the cursor and 300 after it.

## Use a local MLX model

TCE includes local Gemma profiles for Apple silicon. Model weights remain in
the standard Hugging Face cache (`~/.cache/huggingface`); TCE never copies them
into its bundle or Application Support.

```sh
# See the profiles without downloading anything.
./Scripts/local-model.zsh list

# Configure TCE and start the recommended 16 GB profile.
./Scripts/local-model.zsh configure gemma-4-e2b-it
./Scripts/local-model.zsh serve gemma-4-e2b-it

# In another terminal, measure real streaming TTFT and decode speed.
./Scripts/local-model.zsh benchmark gemma-4-e2b-it
```

Restart TCE after changing the configured profile. The first `serve` downloads
only files missing from the shared Hugging Face cache.

| Profile | Intended Mac | Role |
| --- | --- | --- |
| `gemma-3-270m-base` | 8 GB+ | Experimental speed floor; quality is inconsistent |
| `gemma-3-1b-base` | 8 GB+ | Fast raw continuation |
| `gemma-3-1b-it` | 8 GB+ | Promptable text-only alternative |
| `gemma-4-e2b-base` | 16 GB+ | Higher-quality raw continuation |
| `gemma-4-e2b-it` | 16 GB+ | Recommended for conversation or OCR context |

On a 10-core M4 MacBook Air with 16 GB unified memory, the current measured
MLX baselines are:

| Model | Prefill | Decode | Peak model memory |
| --- | ---: | ---: | ---: |
| Gemma 3 270M base 4-bit | 7,054 tok/s | 345 tok/s | 0.37 GB |
| Gemma 3 1B base 4-bit | 1,568 tok/s | 133 tok/s | 0.95 GB |
| Gemma 3 1B IT 4-bit | 1,520 tok/s | 129 tok/s | 0.95 GB |
| Gemma 4 E2B IT 4-bit | 1,645 tok/s | 59 tok/s | 2.87 GB |

The real HTTP benchmark for Gemma 4 E2B IT measured a 220 ms warm median TTFT,
271 ms median total latency, and 50 tok/s mean streamed decode rate. Its first
cold request measured approximately 702 ms TTFT.

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
- OpenAI-compatible HTTP works now. Native llama.cpp/MLX loading and persistent ACP sessions for Codex/Claude belong behind the same provider boundary but are not implemented yet.
- Tab acceptance uses a short-lived pasteboard swap because that works in more apps than direct AX replacement.
- Some custom editors expose incomplete Accessibility text or caret information.
- The app is ad-hoc signed and not notarized.
- Multi-display caret-coordinate handling is only a first pass.

## Project layout

- `CompletionCore`: shadow text buffer and latest-request-only scheduler.
- `TabCompletionsEverywhere`: menu-bar app, event tap, Accessibility reader, provider, overlay, and acceptance.
- `CompletionCoreTests`: focused behavior tests. They require the XCTest runtime included with full Xcode.

## Next slices

1. Add latency instrumentation with buffered, off-hot-path persistence.
2. Add a persistent llama.cpp engine with prompt-state reuse and interruptible decoding.
3. Add MLX generation and memory-pressure controls.
4. Add persistent ACP clients for Codex and Claude rather than spawning a CLI process per completion.
5. Learn per-app editor quirks and add a compatibility matrix.

The proposed privacy-local learning architecture is documented in
[`docs/LOCAL_VOCABULARY.md`](docs/LOCAL_VOCABULARY.md).
