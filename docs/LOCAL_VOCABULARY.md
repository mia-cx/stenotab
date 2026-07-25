# Personal vocabulary and phrase model

## Current implementation

`PersonalLanguageModel` is an encrypted, rebuildable projection of the
canonical event corpus. It learns:

- personal words and preferred capitalization;
- one-to-five-token transitions;
- recency;
- application, website, input-kind, and language scope evidence;
- accepted-suggestion and typed-through positive feedback; and
- strong negative weight for immediate reversion.

Direct typing contributes `1.0` evidence, exact typed-through suggestions
`1.5`, and accepted suggestions `2.5`. A reversion subtracts four times its
count during ranking. These are policy values, not schema, and can be tuned
without migrating the corpus.

## Local completion

Before scheduling model inference, the in-memory projection can generate up to
eight tokens from the longest known context. It supports both next-word and
partial-word completion while preserving learned casing and punctuation.

StenoTab displays the result without calling the model only when:

- net evidence clears the model threshold;
- the winning candidate clears the runner-up margin; and
- resulting confidence is at least `0.70`.

One unconfirmed use is never enough. Repeated evidence is required so a typo
does not immediately become vocabulary.

## Architecture

```text
global input event
    -> shadow buffer update
    -> in-memory learning accumulator
    -> background personalization actor
    -> encrypted SQLite event + projection

completion request
    -> immutable in-memory PersonalLanguageModel
    -> high-confidence local completion, or
    -> async retrieved prompt context + configured provider
```

No SQLite or embedding work runs synchronously in the global event-tap
callback. All derived state can be deleted and rebuilt from the encrypted event
ledger.

## Inspection and deletion

The Personalization settings page shows the strongest learned vocabulary with
preferred casing, evidence, and recency. It also exposes recent canonical
writing episodes and accepted suggestions.

Deleting a record or all history for an application rebuilds vocabulary and
phrase counts from the remaining events. Export produces the canonical corpus,
not opaque projection internals. Delete All removes events, scopes,
embeddings, checkpoints, and projections.

## Deferred work

- Current website detection, which will populate the existing website scope.
- Semantically indexing directly typed edit pairs with stable derived IDs.
- Search, pin, and single-token suppression in the vocabulary inspector.
- Optional scheduled LoRA/QLoRA training, tracked separately in GitHub issue
  #2 and never required for classical personalization.
