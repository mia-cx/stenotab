# Personal vocabulary and phrase model

## Current implementation

`PersonalLanguageModel` is an encrypted, rebuildable projection of the
canonical event corpus. It learns:

- complete whitespace-delimited editor words and preferred capitalization;
- one-to-five-word phrase transitions;
- recency;
- application, website, input-kind, and language scope evidence;
- accepted-suggestion and typed-through positive feedback; and
- strong negative weight for immediate reversion.

Direct typing contributes `1.0` evidence, exact typed-through suggestions
`1.5`, and accepted suggestions `2.5`. A reversion subtracts four times its
count during ranking. These are policy values, not schema, and can be tuned
without migrating the corpus.

Keyboard-event fragments are never vocabulary entries. Input events identify
that an editor changed, but the projection extracts affected complete words
from the reconstructed editor text. Surrounding punctuation is discarded;
internal punctuation such as apostrophes and hyphens remains part of the word.

The raw vocabulary table is not appended to the model prompt. It powers local
partial-word and phrase completion, and can provide aggregate evidence to the
automatic voice assessment. Prompt-time personalization comes from retrieved
full examples and the compact voice assessment instead.

## Voice assessment

The periodic assessment derives compact first-person guidance from complete
writing samples. In addition to length, casing, punctuation, contractions,
questions, emoji, and technical terminology, it now detects:

- sustained British English spelling preferences;
- sustained American English spelling preferences;
- a repeated mixture of both spelling systems; and
- sustained switching between languages, such as English and Dutch.

Dialect classification requires at least three distinct dialect markers in
three separate samples. Repeating one spelling is insufficient. Language
detection ignores short samples and requires several high-confidence samples
for every language it reports. The analyzer is versioned so an application
update can rebuild an older saved assessment from retained history immediately.

## Local completion

Before scheduling model inference, the in-memory projection can generate up to
eight words from the longest known context. It supports both next-word and
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
