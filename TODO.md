# TODO

Open work that is deliberately deferred, with the reasoning that makes it
non-obvious. Newest first.

## Track which episodes a training run consumed

**Why:** so retraining does not refit the same data every round, so an existing
QLoRA adapter can be extended instead of rebuilt, and so old episodes can be
reclaimed for space.

`CompletionEpisodeCapture` now provides the stable episode ID, exact hydrated
model input, streamed suggestion revisions, literal acceptance spans, typed
through text, final field, and outcome. The optional training subsystem should
consume that public shape rather than depending on its deduplicated SQLite
storage representation.

### A boolean "used" flag is the wrong model

`docs/CONTINUAL_MODEL_PERSONALIZATION.md` requires a replay buffer — new
examples mixed with a bounded sample of older ones — to avoid catastrophic
forgetting. So an episode being "used" is not terminal; it will be used again,
deliberately. What matters is *which adapter* consumed it.

Record the relationship, not a flag: `(episodeID, adapterID)`, or a per-run
selection list. `AdapterManifest.corpusRevision` already exists as the field to
hang this off.

Each committed training run should record:

- adapter/checkpoint ID and parent checkpoint ID;
- base-model repository, revision, and quantization identity;
- training recipe and dataset-selection policy versions;
- every selected completion-episode ID and its immutable content fingerprint;
- run state (`prepared`, `training`, `committed`, or `failed`);
- start/end time and resulting adapter path/fingerprint; and
- evaluation metrics used to accept or reject the checkpoint.

Only mark the selection as consumed when the adapter and ledger entry have been
saved atomically. Failed or interrupted runs leave those episodes eligible for
retry. Compatibility includes the base-model revision, quantization, adapter
architecture, and training-recipe version.

### Use a monotonic sequence for the watermark, timestamps for retention

For "what is new since the last run", a monotonic sequence number (SQLite rowid
or an explicit counter) is safer than wall-clock time: episodes can be written
out of order, and a clock change would silently skip or duplicate a range.
Timestamps are the right key for *retention* decisions, just not for
correctness of the training set.

Cheapest correct design: each adapter records the highwater sequence it trained
through; "new examples" is everything above it. Replay selections dip below the
watermark and do need recording per-run if runs are to be reproducible.

### Reusing an existing adapter compounds drift

Continuing from the previous adapter rather than from base is the point of
`AdapterManifest.parentAdapterID`. But a resumed adapter must still be
evaluated against the **base**, not only against its parent — otherwise each
round beats the last while the whole chain drifts below base. See the
two-baseline gate note below.

If the base model changes, the lineage is void and training restarts from
scratch. The corpus survives; only the weight delta is lost.
`AdapterCompatibility` already refuses the mismatched adapter, so this fails
safe.

### Retention has two hazards that are easy to miss

1. **The frozen validation slice must never be deleted.** Comparing adapters
   across rounds only means something if the held-out set is stable. Retention
   has to treat validation episodes as pinned, or every gate result becomes
   incomparable to the last.

2. **Deleting an episode does not un-train it.** The adapter keeps its
   influence. So row deletion is a *storage* measure, not a *privacy* one — and
   "delete my data" means both things to a user. Privacy-motivated deletion has
   to invalidate or retrain the adapter as well, otherwise the promise is not
   kept. Worth surfacing in the UI as two distinct actions.

An edited, deleted, or excluded source episode should mark every affected
adapter lineage stale. Rebuild from the remaining eligible corpus rather than
silently extending weights that still contain deleted data. Preserve enough
provenance for the UI to explain which corpus and lineage produced an adapter.

For space specifically: the heavy fields are the complete field snapshots and
any OCR context, not the text targets. Prefer dropping those first and keeping
the derived training projection, which is small and is what training actually
reads.

## Replace the arbitrary activation thresholds

`AdapterActivationPolicy.minimumLossImprovement = 0.01` (nats) and
`minimumHeldOutExamples = 25` were picked by hand and are both wrong.

Token-level NLL has a standard deviation of roughly 2–3 nats, so detecting a
0.01-nat difference at 3σ needs on the order of 500,000 held-out tokens — far
more than a personal corpus will ever hold. As written, the gate cannot fire on
evidence; it fires on noise, which is the exact failure it exists to prevent.

A real style effect should be nearer 0.05–0.3 nats, which needs about 5,000
held-out tokens (roughly 150–250 episodes) to detect.

Fix: replace the fixed delta with a **paired test** over per-example NLL
differences (sign test or paired t), so a small corpus correctly fails to
activate rather than activating on noise, and raise
`minimumHeldOutExamples` to ~150–250.

Schema-independent; can be done before the rebase.

## Split the evaluation baseline in two

`AdapterEvaluation` has a single `baselineValidationLoss`, which leaves it
ambiguous whether "baseline" means the unadapted base or the previous adapter.
That ambiguity is a ratchet: if a candidate only has to beat its parent, the
chain can drift arbitrarily far below base while every step looks like an
improvement.

`docs/CONTINUAL_MODEL_PERSONALIZATION.md` already specifies comparing against
"both the prior adapter and the raw base". The implementation should require:
beats **base** by a detectable margin, **and** does not regress against the
**previous adapter**.

Schema-independent; pairs naturally with the paired-test change above.

## Add a memorization gate before activation

An adapter is personal data that is harder to inspect than the corpus, and
weight updates can memorize sensitive strings. Erring toward mild overfit is the
right trade — it is detectable and reversible, where margin-objective divergence
is silent and compounding — but only with a memorization check to bound it.

Cheap version: generate continuations for held-out prefixes and reject the
candidate if any output reproduces a verbatim span of ~8 or more tokens from a
training example that is not present in the prompt.

Schema-independent.

## Weight training examples by provenance

Once the episode schema is known, weight examples by who authored the desired
output:

| Episode | Desired output authored by | Weight |
| --- | --- | ---: |
| Suggestion rejected, user typed their own | user | 1.0 |
| No suggestion shown, user typed | user | 1.0 |
| Accepted then reverted | user (the replacement) | 1.0 |
| Accepted and kept | **model** | 0.3–0.5, capped as a corpus fraction |

Only the last row needs suppressing, and it is the one that looks most like
success. Training on accepted model output is how the model amplifies its own
phrasing.

**Time-sensitive:** provenance is not reconstructible after the fact. If an
episode stores only its final text, the record of which spans came from accepted
suggestions is gone permanently for every episode captured before the field
exists. Correlating `AcceptedSuggestionCapture.insertion` against the final text
may work, but not if the text was edited afterwards. Confirm this is reliable
before a corpus accumulates, because it cannot be backfilled.

## Wire the MLX Swift engine

The concrete `LocalInferenceEngine` over MLX Swift, plus the trainer call behind
`AdapterTrainingSession`. Both are the same binding work and both are what a
first real training run exercises.

Resolved dependency versions and the API surface needed — including
`KVCache.trim(_:)`, which is the hook `PrefixCacheReusePolicy` exists to drive —
are recorded in `docs/ADAPTER_FEASIBILITY_FINDINGS.md`. Note the interop trap
documented there: Swift's `LoRAParameters` defaults `scale` to 10.0 while Python
mlx-lm defaults to 20.0.

Adding the dependency makes every build pull mlx-swift's Metal kernels and
swift-syntax's macros, so expect a slow first build and land it together with a
working implementation rather than ahead of one.

## Retire the Python trainer once Swift is validated

`Scripts/personalization/train_adapter.py` is the only remaining consumer of
Python `mlx-lm`, and it is kept deliberately: it is the only thing that has
produced a working adapter end to end, so it is the oracle for validating the
Swift trainer.

Validate the Swift trainer against it on the same corpus for the same target
module set and count (the 70/30 q/v split on gemma4), a comparable validation
loss trajectory, and an adapter that shifts output in the same direction at the
same scale — that last one matters because of the 10.0/20.0 scale discrepancy.

Then delete it and drop `mlx-lm` from `setup-mlx-env.sh`, leaving only `mlx`,
`numpy`, `safetensors` and `huggingface_hub` for the packaging converter.
