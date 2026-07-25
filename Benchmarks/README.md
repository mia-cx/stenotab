# Autocomplete benchmark fixtures

`autocomplete-fixtures.json` stores semantic autocomplete inputs separately
from any inference backend's request envelope. The same case can therefore be
rendered as:

- a raw Base-model text-completion prompt;
- separate system and user chat messages;
- an incremental prefix-cache request sequence; or
- a production-path request including sanitizer and partial-word handling.

The fixtures are synthetic and contain no captured user data.

## Commands

```sh
# Inspect the suite without loading a model.
./Scripts/benchmark-local-model.py --list-cases

# Print fully rendered OpenAI-compatible request bodies.
./Scripts/benchmark-local-model.py \
  --model mlx-community/gemma-4-e2b-4bit \
  --api-style textCompletions \
  --print-prompts

# Run the growing-prefix sequence for one case against any compatible server.
./Scripts/benchmark-local-model.py \
  --url http://127.0.0.1:8081/v1 \
  --model mlx-community/gemma-4-e2b-4bit \
  --api-style textCompletions \
  --case discord-cache-debug \
  --cache-sequence
```

## Design

Each continuation case includes application and input metadata, OCR content,
optional clipboard content, a user-voice description, cursor-adjacent text,
and loose quality guardrails. `example_continuations` are illustrative rather
than exact-match golden answers: multiple continuations can be equally good.
`forbidden_substrings`, empty-input behavior, maximum word count, and the
partial-word regression are suitable for deterministic checks.

`cache_sequence` represents the same field as it grows during typing. Use the
steps in order, without restarting or unloading the model, to measure
longest-prefix reuse. Report cold and warm runs separately.

## Benchmark hypothesis

**Hypothesis:** A runtime with effective longest-prefix caching will reduce
incremental autocomplete TTFT without changing decode throughput or completion
quality.

**Metrics:** p50/p95 time to first token, time to first complete word, total
time, prompt/cache-hit tokens where available, decode throughput, cancellation
latency, and resident memory after warmup.

**Acceptance:** Prefer a backend or cache implementation when its incremental
TTFT p95 is below 250 ms on the target M4 Air, it materially beats the current
server on at least two context sizes, and it passes every deterministic quality
guardrail.

Final confirmation must run the production Stenotab request and sanitization
path, not only the raw HTTP benchmark.

Use `--prompt-style contextual` to exercise the proposed OCR, clipboard, and
voice envelope. Use `--prompt-style production` as a compact-prompt control.
Comparing both separates context quality from prompt-prefill cost and makes
instruction-boundary regressions visible.

## Classical personalization microbenchmark

`PersonalizationBenchmark` isolates local work that happens before provider
inference:

```sh
swift run -c release PersonalizationBenchmark
```

Cases:

| Case | Representative corpus | Acceptance |
| --- | --- | ---: |
| `local_completion` | 2,020 learned phrases | p95 ≤ 1 ms |
| `query_embedding` | warmed Apple NL 11-word query | p95 ≤ 20 ms |
| `frecent_retrieval` | top five of 10,000 examples | p95 ≤ 20 ms |
| `semantic_retrieval` | top five of 2,000 × 512-d vectors | p95 ≤ 50 ms |

The harness consumes every result into a checksum and runs in release mode to
avoid debug-build noise and optimizer-elided work.

Baseline on the development Apple-silicon Mac, 2026-07-25:

| Case | p50 | p95 |
| --- | ---: | ---: |
| `local_completion` | 0.022 ms | 0.022 ms |
| `query_embedding` | 3.675 ms | 5.157 ms |
| `frecent_retrieval` | 9.090 ms | 11.091 ms |
| `semantic_retrieval` | 5.505 ms | 7.552 ms |

These numbers establish regression budgets for local logic. They do not
replace an end-to-end warm TTFT run against `llama-server`.
