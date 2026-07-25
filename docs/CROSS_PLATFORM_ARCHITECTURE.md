# Cross-platform architecture direction

Status: exploratory guidance, not a commitment to ship StenoTalk, Windows, or
Linux support.

## Why document this now

StenoTab may eventually have two related product surfaces:

- **StenoTab**: inline completion in arbitrary text fields.
- **StenoTalk**: local-first dictation and optional LLM cleanup, inserting text
  through the same system-wide text-field integration.

Windows and Linux are also plausible future targets. The expensive,
platform-specific part of each product is observing and modifying text in other
applications. Completion, transcription cleanup, personalization, inference
routing, and privacy policy should not become inseparable from macOS
Accessibility or AppKit.

The goal now is not to choose a forever language. It is to keep the seams clean
enough that a second implementation can be added without rewriting the whole
product.

## Working decision

Keep the macOS application in Swift. Keep Apple-only work in the `StenoTab`
target. Grow `CompletionCore` into a platform-neutral product engine, but do not
rewrite it into another language until a real second platform justifies the
cost.

Design the core boundary so it could later be implemented by:

1. cross-platform Swift;
2. a Rust library behind a stable C ABI;
3. a local Rust/C++ service reached through versioned IPC.

This keeps the current implementation simple without making Swift types,
AppKit objects, or Accessibility handles part of the permanent product
contract.

## What Swift can interoperate with

Swift can import C APIs directly. Swift 5.9 and later also support direct C++
interoperability on Swift-supported platforms, including Windows, although the
C++ feature remains actively evolving and has constraints around exceptions,
standard-library types, ownership, and compiler compatibility.

Rust and most other systems languages can expose a C ABI. A Rust core can
therefore be consumed from Swift through a small generated C header without
making Rust-specific types visible to Swift.

For a durable product boundary:

- Prefer a small C ABI or versioned local IPC over exposing a large C++ object
  model directly.
- Pass fixed-width scalars and explicit byte buffers across FFI.
- Use opaque handles for stateful objects.
- Define who allocates and frees every buffer.
- Never expose Swift `String`, Rust `String`, C++ STL containers, exceptions,
  or language-specific async types across the stable boundary.

Direct C++ interop is still useful inside an adapter—for example, when wrapping
a native inference library—but should not define StenoTab's domain model.

Official references:

- [Swift platform support](https://www.swift.org/platform-support/)
- [Swift and C++ interoperability](https://www.swift.org/documentation/cxx-interop/)
- [C++ interoperability constraints](https://www.swift.org/documentation/cxx-interop/status/)

## Product boundary

The portable side should think in terms of a text session, not Accessibility
elements, windows, or key events.

An illustrative Swift-shaped contract is:

```swift
struct TextSessionSnapshot: Sendable {
    let sessionID: String
    let prefix: String
    let suffix: String
    let application: ApplicationContext
    let inputKind: InputKind
    let isSecure: Bool
    let contextRevision: UInt64
}

protocol TextPlatform: Sendable {
    func events() -> AsyncStream<TextPlatformEvent>
    func snapshot() async -> TextSessionSnapshot?
    func insert(_ text: String, in sessionID: String) async -> Bool
    func show(_ suggestion: SuggestionPresentation) async
    func hideSuggestion() async
}

protocol CompletionEngine: Sendable {
    func suggest(_ request: CompletionRequest) async -> CompletionResult
}
```

This is not a proposed final API. It illustrates the important ownership rule:
the platform shell converts native state into product-domain values, and the
engine returns intent rather than manipulating native UI objects.

## Responsibility map

### Portable product engine

- Text-session state and reconciliation rules
- Debouncing, latest-request-only scheduling, and cancellation semantics
- Completion request/response types
- Prompt construction and output sanitation
- Partial-word completion and suggestion consumption
- Provider routing and model-independent inference contracts
- Refill/prefetch policy
- Personal vocabulary, retrieval, and voice-profile policy
- Privacy decisions that can be expressed from normalized metadata
- Latency and acceptance-rate event definitions
- StenoTalk transcript cleanup and spoken-command interpretation

### Platform shell

- Permissions and onboarding
- Active application, window, website, and input-kind discovery
- Secure-field detection before content crosses into the engine
- Keyboard hooks and input events
- Accessibility/UI Automation/AT-SPI text snapshots
- Text insertion
- Caret geometry, typography sampling, and ghost-text rendering
- Screen capture and native OCR
- Clipboard access
- Microphone capture and audio-device handling
- App settings, launch-at-login, updates, signing, and packaging

### Replaceable adapters

- OpenAI-compatible, ACP, and local-model providers
- llama.cpp lifecycle and transport
- OCR implementation
- Embedding store
- ASR engine
- Encrypted persistence
- Metrics persistence

Inference runtimes should remain replaceable. An out-of-process model server is
often preferable to FFI because it isolates crashes, permits independent
updates, and makes local and remote providers share one conceptual boundary.

## Current codebase assessment

The existing package already has the beginning of the right split:
`CompletionCore` does not import AppKit or ApplicationServices, and the
`StenoTab` executable owns Accessibility, event taps, literal Unicode event
insertion, and the overlay. `StenoTabPersistence` isolates encrypted SQLite and
Keychain-backed storage from both layers.

The remaining architectural pressure points are:

1. **Runtime state machine**
   `CompletionCoordinator` owns portable scheduling and suggestion lifecycle
   rules alongside macOS timers, permissions, and overlay calls. Move the
   behavior behind one engine boundary before adding more context sources.
   This is primarily an in-process dependency.

2. **Provider contract**
   `CompletionRequest`, `CompletionResponse`, `CompletionProvider`, HTTP
   transport, and provider construction currently live in the macOS
   executable. The request/result contract belongs in the core; HTTP and
   process management are adapters. This is a ports-and-adapters dependency.

3. **Geometry in the core**
   `CompletionCore` currently imports CoreGraphics for overlay geometry. Replace
   those public values with small product-owned point/rect/size types, or move
   rendering geometry into the macOS shell, before claiming the target is
   portable.

4. **Context acquisition versus context policy**
   Accessibility, OCR, clipboard, and audio capture are platform operations.
   Deciding what context may be retained or sent to a provider is product
   policy. Normalize captured context before the policy layer sees it.

Boundary tests should exercise a fake `TextPlatform` and a fake
`CompletionEngine` through complete behaviors: typing, debounce, stale-result
rejection, exact-match consumption, word acceptance, full acceptance, refill,
focus changes, and secure-field rejection. These tests are more durable than
testing each helper in isolation.

## StenoTalk

StenoTalk should be a sibling feature using the same text-platform shell, not a
fork of StenoTab.

Its portable pipeline is:

```text
audio capture -> ASR -> transcript normalization -> optional LLM cleanup
              -> privacy/policy gate -> text insertion
```

Use a dedicated ASR adapter for the transcription hot path. A multimodal LLM
can be evaluated as an optional cleanup or context-reasoning stage, but the
architecture should not require one model to perform both ASR and completion.
That avoids coupling product behavior, latency, and memory pressure to a single
model.

Raw audio and screenshots should be ephemeral by default. Persist derived text,
vocabulary, or embeddings only under an explicit local personalization policy.

## Platform notes

### macOS

Continue with Swift, AppKit, Accessibility, Core Graphics event taps, native
screen capture/OCR, and native audio APIs. This is the reference shell.

### Windows

Build a small spike before selecting the shell language. Likely native
facilities include UI Automation for text fields, Windows input hooks, and a
native overlay. C#, Rust, or C++ may be a more pragmatic shell than Swift even
if the product engine remains reusable.

Swift is officially supported for Windows development and deployment, so a
shared Swift engine is possible. That fact alone does not make it the best
choice: packaging, native UI integration, accessibility coverage, debugging,
and contributor ecosystem must be measured in the spike.

### Linux

Treat Linux as a distinct target, not a free consequence of Windows support.
X11 and Wayland have different capture and input-injection constraints, and
desktop accessibility coverage varies. The portable engine can be shared, but
the shell may require compositor- and desktop-specific adapters.

## Evolution plan

### Now: preserve optionality

- Keep AppKit, ApplicationServices, CoreText, and native handles out of domain
  contracts.
- Move provider request/result protocols into `CompletionCore`.
- Replace the CoreGraphics dependency in `CompletionCore`.
- Describe behavior at the text-session boundary.
- Keep model servers and ASR engines behind adapters.

### When StenoTalk starts

- Extract a shared text insertion/context shell.
- Add audio capture and ASR ports.
- Reuse privacy, provider, personalization, and insertion policies.
- Benchmark dedicated ASR models separately from LLM cleanup.

### When a second desktop platform starts

- Implement one narrow end-to-end vertical slice: observe a text box, request a
  deterministic completion, render it, and accept it.
- Measure Swift-on-Windows ergonomics against a Rust/C#/C++ shell.
- Only then decide whether to keep the engine in Swift, migrate it behind a C
  ABI, or host it as a local service.

The migration trigger is a working second shell and demonstrated duplication,
not the possibility that another platform may exist someday.
