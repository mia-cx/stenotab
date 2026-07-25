# Continual local model personalization

## Status

Feasibility and design note. This is not yet a roadmap commitment.

## Summary

StenoTab can plausibly learn a model-specific, local representation of one
user's writing style over time. The practical mechanism is not a continuously
running full-model RLHF loop. It is:

1. continuously collecting explicit and implicit writing feedback;
2. preserving that feedback in a model-independent local corpus;
3. periodically training a small parameter-efficient adapter while the Mac is
   idle; and
4. loading that adapter alongside the unchanged local base model.

A low-rank adapter (LoRA or QLoRA during training) is the most realistic first
implementation. The adapter is stored separately from the base model, can be
enabled at a configurable strength, and can be rolled back without touching the
model file. `llama.cpp` supports separately loaded GGUF LoRA adapters in both
its completion tool and `llama-server`.

This could make completions substantially more personal, especially for stable
voice traits such as capitalization, punctuation, contractions, vocabulary,
sentence length, and common phrasing. It is less likely to replace prompt-time
retrieval: the prompt still carries immediate, app-specific, and semantically
relevant information that weights should not memorize.

The recommendation is to prototype this behind an experimental flag, but not
to implement literal per-keystroke training.

The default design must not keep an inference copy and a training copy of the
model resident at the same time. StenoTab should serialize them:

```text
stop and unload llama-server
    -> run a bounded QLoRA training session
    -> unload the trainer
    -> restart llama-server with the validated adapter
```

That avoids a literal two-model RAM footprint. Training can still use
substantially more memory than ordinary inference because it needs activations,
gradients, and optimizer state. A seamless mode that continues serving
completions while training would be an explicit high-impact opt-in with clear
memory, battery, and thermal warnings.

## This is not quite RLHF

Classic RLHF generally means:

1. collect comparisons;
2. train a reward model;
3. optimize a language model policy against that reward, commonly with PPO.

That is too complex, unstable, and expensive for a continuously running desktop
feature. StenoTab also receives much better supervision than a generic thumbs
up/down interface: it can observe the exact proposed text, the accepted span,
what the user ultimately wrote instead, and whether accepted text was later
edited away.

Three increasingly ambitious objectives are possible:

### 1. Supervised continuation tuning

Train on the user's final writing as the target continuation. Mask the loss over
the contextual prompt so only the user's continuation contributes to training.

This is the best first version. It directly teaches voice and vocabulary,
requires no rejected sample, and works with both directly typed text and
accepted suggestions.

### 2. Pairwise preference tuning

Construct pairs such as:

```text
context:  the complete prompt and text before the cursor
chosen:   what the user ultimately wrote
rejected: the suggestion they replaced or edited away
```

Direct Preference Optimization (DPO) can train from such pairs without a
separate reward model. However, a suggestion the user did not accept is not
automatically bad. They may have kept typing because only the first word was
useful, because Tab had another meaning in that app, or because the completion
arrived too late. Weak or ambiguous rejections must not become strong negative
examples.

### 3. Online preference optimization

Continually update an adapter from an evolving stream of feedback. This is the
closest match to the original idea, but it is also where catastrophic
forgetting, noisy labels, preference drift, and runaway feedback loops become
serious. It should be considered only after batched supervised tuning and
offline DPO can beat the untuned model on held-out personal examples.

## Signals StenoTab can observe

### Strong positive signals

- Option-Tab accepts an entire suggestion.
- Repeated Tab accepts several consecutive words from the same suggestion.
- The user types the visible suggestion exactly.
- Accepted text remains in the field through submission or focus loss.
- The user repeatedly writes the same spelling, phrase, or stylistic pattern.

### Strong negative signals

- The user accepts text and immediately deletes or replaces it.
- The final submitted continuation conflicts with a shown suggestion.
- The same suggestion pattern is repeatedly accepted only partially and the
  remainder is consistently rewritten.

### Ambiguous signals

- A suggestion disappears without being accepted.
- The user keeps typing before a suggestion finishes streaming.
- Escape is pressed.
- Focus changes.
- A completion is shown but never acted on.

Ambiguous events are useful for ranking and product metrics but should not
directly update weights as negative labels.

Each training event should preserve:

- the complete input field and cursor/selection state;
- the bounded prompt actually sent to inference;
- app, website, and input-kind scope;
- model and adapter identity;
- the complete streamed suggestion;
- the exact accepted span;
- the eventual user-authored continuation;
- subsequent edits to accepted text;
- latency and whether the suggestion was visible long enough to judge;
- explicit privacy/exclusion state.

The canonical encrypted history described in
`LOCAL_HISTORY_RETRIEVAL.md` should remain the source of truth. Training
examples are derived, reproducible projections of that history.

## Recommended architecture

```text
typing and completion events
          |
          v
encrypted model-independent corpus
          |
          +----------------------+----------------------+
          |                      |                      |
          v                      v                      v
frecent examples       semantic retrieval       voice assessment
in the prompt          in the prompt             in the prompt
          |
          v
quality-filtered training projection
          |
          v
idle, batched LoRA/QLoRA trainer
          |
          v
versioned model-specific adapter
          |
          v
StenoTab-owned llama-server + unchanged GGUF base model
```

### Separate durable layers

#### 1. Personalization corpus

Model-independent and encrypted. It contains the user's writing events,
accepted completions, preference pairs, provenance, and privacy scopes. It
survives model removal and is portable to future local models.

#### 2. Derived prompt personalization

Frecent examples, semantically relevant examples, local vocabulary, and
periodic voice assessments. These work immediately with any compatible local
or remote model.

#### 3. Adapter checkpoint

Model-specific learned weights. Store separately from the Hugging Face model
cache and never delete them merely because a model file is removed.

#### 4. Adapter manifest

At minimum:

```json
{
  "baseRepository": "owner/model",
  "baseRevision": "immutable commit",
  "baseArchitecture": "gemma...",
  "tokenizerFingerprint": "...",
  "tensorLayoutFingerprint": "...",
  "trainingBackend": "mlx-lm",
  "trainingBackendVersion": "...",
  "adapterFormat": "safetensors-or-gguf",
  "rank": 8,
  "targetModules": ["..."],
  "corpusRevision": 42,
  "createdAt": "...",
  "parentAdapter": "...",
  "evaluation": {
    "personalValidationLoss": 0.0,
    "acceptanceProxy": 0.0
  }
}
```

An adapter is tied to the base checkpoint, tokenizer, tensor layout, and target
modules. It is generally not transferable to a different model family, size,
or revision. It may be reusable across GGUF quantizations derived from the
exact same base checkpoint if their tensor layout remains compatible, but this
must be validated rather than inferred from the display name.

When users switch models:

- prompt retrieval and voice assessment transfer immediately;
- an adapter for the exact base identity can be reused;
- an incompatible model starts without a weight adapter;
- StenoTab can bootstrap a new adapter later from the same durable corpus.

The user therefore does not lose personalization when changing models. They
temporarily lose only the model-specific weight delta.

## Runtime ownership

For adapter-backed personalization, StenoTab should own the local
`llama-server` lifecycle.

`llama-server` can load one or more LoRA adapters separately from the GGUF base,
set their scales, and choose adapters per request. Separate loading preserves
mmap model loading and avoids creating a fused duplicate model. Requests with
different adapter configurations are not batched together, but StenoTab is
normally a single-user, low-concurrency client.

Reusing an arbitrary existing OpenAI-compatible server is insufficient unless
StenoTab can verify:

- the exact selected base model identity;
- support for the selected adapter format;
- the loaded adapter identity and scale;
- a safe way to reload a new checkpoint; and
- compatible tokenization and prompt behavior.

An external server can remain supported for ordinary inference. Continual
weight personalization should be available only when StenoTab controls or can
fully interrogate the local runtime.

Training does not need to run inside `llama-server`. A separate trainer can
produce versioned adapters, after which StenoTab atomically switches the
inference runtime to a validated checkpoint. In the default mode, the separate
trainer and inference server run at different times, not concurrently.

## Apple Silicon training path

MLX-LM is the most practical current training backend on Apple Silicon. It
supports LoRA, DoRA, full fine-tuning, and QLoRA when the source model is
quantized. It saves learned adapter weights separately and can resume an
existing adapter.

There is an important integration risk:

- StenoTab currently performs inference from a GGUF model with llama.cpp.
- MLX-LM normally trains a Hugging Face or MLX-format model.
- llama.cpp expects inference adapters in GGUF format.

The first prototype must prove an end-to-end path for the selected Gemma model:

```text
exact HF base revision
    -> quantized MLX training representation
    -> LoRA adapter checkpoint
    -> lossless/validated GGUF LoRA conversion
    -> the existing quantized GGUF base in llama-server
```

MLX-LM documents only limited GGUF export support for fused models, and
llama.cpp documents conversion from Hugging Face LoRA format. We should not
assume an MLX adapter is directly consumable by llama.cpp until a round-trip
test demonstrates matching tensors and output.

This path may also require a second model representation for training. If the
trainer cannot operate on the existing GGUF, a 16 GB Mac may need both:

- the inference GGUF in the Hugging Face cache; and
- an MLX or original Hugging Face representation used for QLoRA.

The adapter itself is small, but the training representation could add
gigabytes. Avoiding a duplicate base model is therefore a prototype goal, not a
property we can promise yet.

Possible outcomes:

1. **Best case:** train from a compatible cached representation, convert the
   adapter to GGUF, and keep llama.cpp for inference.
2. **Acceptable case:** download a temporary MLX training representation,
   produce the adapter, then reclaim the temporary weights.
3. **Fallback:** use MLX for both training and personalized inference.
4. **Long-term:** implement or adopt a trainer that updates LoRA weights
   directly against the GGUF/ggml tensor layout.

## Performance and storage impact

Exact numbers depend on model architecture, adapter rank, targeted layers,
context length, training sequence length, and backend. They must be benchmarked
on the 16 GB M4 Air target rather than guessed from desktop-GPU results.

### Inference

Expected characteristics for a small rank-4 or rank-8 adapter:

- adapter storage and resident memory are usually tens of megabytes for a
  roughly 2B-parameter model, but can grow toward hundreds of megabytes when
  more modules or a higher rank are targeted;
- applying an unfused adapter adds extra low-rank matrix operations, so TTFT and
  generation throughput may regress;
- a conservative prototype budget is less than 5% median TTFT regression and
  less than 10% tokens-per-second regression;
- adapter loading or a server restart can add a one-time warm-up delay;
- loading different adapter configurations per concurrent request prevents
  those requests from batching together in llama.cpp.

The adapter size is approximately proportional to:

```text
rank * sum(input_width + output_width)
```

for every targeted linear layer, multiplied by the stored scalar width. A
focused q/v-only adapter is much smaller than adapting attention and every MLP
projection.

### Training

Training is the expensive part:

- gradients, activations, optimizer state, and the training model compete for
  unified memory;
- running the trainer beside `llama-server` may hold two model representations
  and saturate memory bandwidth;
- sustained training causes heat and battery drain even when it technically
  fits;
- long sequence lengths cost far more than short completion windows;
- optimizer checkpoints can be several times larger than the final adapter.

On a 16 GB Mac, StenoTab should assume that simultaneous inference and training
is unacceptable. The safe initial policy is:

- train only while plugged in, thermally healthy, and idle;
- require a meaningful batch, not every keystroke;
- stop and fully unload the inference server before loading the trainer;
- cap sequence length and adapter rank;
- checkpoint atomically;
- unload all training state before restarting inference;
- restart and warm inference only after validation succeeds;
- immediately yield to foreground typing.

This keeps steady-state completion TTFT unchanged and avoids simultaneous base
model residency. The cost is that completions are temporarily unavailable
during an idle training session, followed by a warm-up after the adapter swap.

An optional seamless mode may keep `llama-server` resident while a separate
trainer runs. It must be off by default and presented plainly:

> Continual training may greatly increase memory use, energy consumption, and
> heat. On lower-memory Macs it can cause memory pressure or swap and make both
> StenoTab and other apps slower.

StenoTab should estimate required headroom from the selected model, adapter
rank, sequence length, and recent peak training memory. It should refuse or
automatically fall back to serialized training when the estimate is unsafe.

### Storage

Keep these separate:

```text
Application Support/StenoTab/Personalization/
  corpus.sqlite
  voice-profile.json
  adapters/
    <base-fingerprint>/
      active.json
      checkpoints/
        <adapter-id>/
          adapter.gguf
          manifest.json
          metrics.json
```

Do not place user adapters in the shared Hugging Face cache. Do not remove them
when pruning a base model. Allow:

- inspect/export;
- delete one model's adapter;
- reset to an earlier checkpoint;
- disable weight personalization without deleting data;
- delete all learned data;
- rebuild an adapter from the corpus.

## Why literal continuous updates are unsafe

Updating after each accepted word sounds responsive but creates worse learning
dynamics:

- adjacent examples are highly correlated;
- one accidental acceptance receives disproportionate weight;
- the model can amplify its own phrasing because accepted suggestions become
  future training data;
- short-term topic changes can overwrite long-term voice;
- there is no stable validation point;
- writes and training contend with the latency-sensitive completion path.

Use a replay buffer containing older and newer examples, direct user writing,
and accepted model text with explicit provenance. Weight direct writing more
heavily. Deduplicate near-identical examples. Keep a fixed validation slice that
never participates in gradient updates.

A reasonable first policy is:

- collect continuously;
- train after 100-500 new high-confidence examples;
- mix new examples with a bounded replay sample;
- run a small fixed number of optimizer steps;
- compare against both the prior adapter and the raw base;
- activate only if personal held-out metrics improve without failing generic
  continuation fixtures.

The numbers are experiment parameters, not product defaults yet.

## Evaluation and rollback

Training loss alone is not sufficient. Every candidate adapter should be tested
on:

1. held-out direct user continuations;
2. held-out accepted and rewritten suggestions;
3. StenoTab's generic partial-word and continuation fixtures;
4. prompt-leakage and assistant-voice regressions;
5. repetition, whitespace, and partial-word correctness;
6. TTFT, tokens per second, memory, energy, and thermal impact.

Useful offline measures:

- negative log likelihood of the user's actual continuation;
- rank or probability of the accepted next word;
- edit distance to the user's final continuation;
- preference win rate against the previous adapter;
- repetition and prompt-leakage rejection rates.

Production activation should be transactional:

1. train `candidate-N`;
2. evaluate it;
3. retain the prior active adapter;
4. atomically update `active.json`;
5. restart/reload the server;
6. automatically roll back on crashes, invalid output, or quality guardrails.

An optional low-rate A/B comparison between base, previous adapter, and
candidate can measure actual acceptance without exposing model identity to the
hot path.

## Privacy and product controls

Weight updates can memorize sensitive strings. All existing history exclusions
must apply before an event reaches the training corpus:

- never collect secure or password fields;
- honor global, per-app, and per-site exclusions;
- do not train on clipboard or OCR content as target writing;
- keep provenance so accepted model output is distinguishable from direct user
  writing;
- encrypt the corpus and adapter metadata at rest where practical;
- never upload a corpus or personal adapter without explicit export;
- provide pause, inspect, export, per-app deletion, per-model reset, and
  delete-all controls;
- make personalized local inference visibly distinct from remote API providers.

The adapter itself should be treated as personal data. It is harder to inspect
than the corpus but may encode details from it.

## Proposed implementation slices

### Slice 0: end-to-end feasibility spike

- Pick one exact Gemma base revision and the current recommended GGUF.
- Create a tiny synthetic writing-style dataset.
- Train rank-4 and rank-8 adapters with MLX-LM.
- Determine whether the adapter can be converted to GGUF without fusing.
- Load it through StenoTab's `llama-server`.
- Verify that the raw GGUF remains unchanged.
- Measure adapter size, peak training memory, training time, TTFT, and tokens
  per second on an M4 Air with 16 GB.

Stop if the MLX-to-GGUF adapter path is unreliable or requires a permanently
duplicated model representation that violates the storage budget.

### Slice 1: model-independent event corpus

- Extend the local-history schema with suggestion outcome and final-text data.
- Add privacy filtering, provenance, retention, inspect/export, and deletion.
- Build deterministic SFT examples without training anything.

### Slice 2: offline trainer command

- Produce a versioned adapter manually from an exported local dataset.
- Add fixed train/validation splits, replay, metrics, and rollback.
- Keep it outside the running app until repeatable.

### Slice 3: StenoTab-managed adapter inference

- Own the local server lifecycle.
- Verify base and adapter fingerprints.
- Load adapters separately and expose an adapter-strength control.
- Fall back safely to the raw model.

### Slice 4: idle batched training

- Gate on power, idle time, thermal state, memory pressure, and corpus growth.
- Stop and unload inference before loading the trainer.
- Train a candidate in the background.
- Evaluate and activate transactionally.
- Unload training state before restarting inference.
- Abort and restore inference when the user resumes typing.

### Slice 4b: optional seamless training

- Keep inference and training resident only after explicit opt-in.
- Show a high-impact memory, battery, and thermal warning.
- Estimate available unified memory before every session.
- Disable automatically on memory pressure or excessive swap.
- Benchmark whether the product benefit justifies the doubled model residency.

### Slice 5: preference optimization experiment

- Derive only high-confidence chosen/rejected pairs.
- Compare SFT, DPO, and SFT followed by DPO.
- Ship preference tuning only if it improves real acceptance over SFT alone.

## Go/no-go criteria for a roadmap issue

Create a roadmap issue if Slice 0 demonstrates all of the following:

- an unfused adapter can be trained and loaded over the selected GGUF;
- adapters remain separate from base model files;
- adapter identity can be validated against the exact base;
- personalized output improves on a small held-out style fixture;
- median warm TTFT regression is at most 5%;
- tokens-per-second regression is at most 10%;
- training fits on a 16 GB M4 Air without unsafe memory pressure;
- serialized training does not keep inference and training models resident
  together;
- training can yield immediately to foreground completions;
- storage overhead is acceptable and clearly reported;
- deleting/reinstalling the base model does not delete the corpus or adapter.

If conversion or storage fails, keep the model-independent corpus and prompt
personalization, and reconsider an MLX inference backend specifically for the
personalized-local-model mode.

## Recommendation

Proceed with a bounded feasibility spike, not a production implementation.

The concept is technically sound and unusually well matched to StenoTab because
the product naturally observes real continuation outcomes. The best likely
product is a hybrid:

- retrieval provides immediate and transferable personalization;
- voice assessment provides compact global guidance;
- a small LoRA adapter gradually learns durable stylistic tendencies;
- the literal cursor context remains the source of current intent.

Call the feature **continual local personalization** in product and engineering
language. Reserve **RLHF** for experiments that actually train from explicit
preference comparisons or a reward objective.

## References

- [LoRA: Low-Rank Adaptation of Large Language Models](https://arxiv.org/abs/2106.09685)
- [Direct Preference Optimization](https://arxiv.org/abs/2305.18290)
- [MLX-LM LoRA and QLoRA documentation](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md)
- [llama.cpp completion LoRA documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/completion/README.md)
- [llama-server documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [Hugging Face PEFT LoRA guide](https://huggingface.co/docs/peft/main/conceptual_guides/lora)
- [Hugging Face PEFT checkpoint format](https://huggingface.co/docs/peft/main/developer_guides/checkpoint)
- [An Empirical Study of Catastrophic Forgetting in Large Language Models During Continual Fine-tuning](https://arxiv.org/abs/2308.08747)
- [Cheap and Effective Personalization of Foundation Language Models for Imitating a User's Writing Style](https://openreview.net/forum?id=gsr3t360Xy)
