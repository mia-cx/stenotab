# Local input history and retrieved completion examples

## Goal

Use the user's previous writing and accepted completions as literal few-shot
examples:

```text
Text: <input before the insertion>
Insertion:<literal inserted text>
```

The persisted record and the prompt projection are intentionally different:

- Persist the complete textarea or input-field value at capture time, regardless
  of length.
- Persist the cursor and selection range so the prefix and suffix can always be
  reconstructed.
- Derive bounded rolling windows for embeddings and prompt injection.
- Never truncate the canonical stored field merely because the current prompt
  has a smaller context budget.

This design complements `LOCAL_VOCABULARY.md`. Full writing history is the
source of contextual examples; vocabulary remains a smaller derived index for
names, spelling, and recurring phrases.

## Provenance

Two example sources are useful, and they must remain distinguishable:

1. `user_typed`
   A typing burst authored directly by the user.
2. `accepted_suggestion`
   The exact slice inserted with Tab or Option-Tab.

Accepted text is a strong positive signal, but it began as model output. Keeping
the source allows retrieval experiments to weight direct writing more highly,
or to disable either source without migrating the database.

Rejected portions of a suggestion must never be treated as accepted writing. If
Tab accepts one word from a longer suggestion, only that inserted slice becomes
the example's insertion. A later Tab creates another example whose full input
already contains the previously accepted word.

## Capture model

An `input_episode` represents one continuously observed focused field. An
`input_snapshot` is an immutable copy of the entire field at an important
moment.

For an accepted suggestion, capture the snapshot immediately before insertion:

```text
field_text       = complete AXValue of the focused field
selection_start  = current selection start in UTF-16
selection_length = current selection length in UTF-16
insertion_text   = exact accepted slice, including literal whitespace
```

The prompt input at the cursor can then be reconstructed:

```text
prefix = field_text[..<selection_start]
suffix = field_text[(selection_start + selection_length)...]
```

For direct typing, aggregate a burst instead of storing one example per
keystroke. Capture the complete field before the burst and store the exact burst
as its insertion. Finalize a burst on a short idle period, focus change,
submission, or a semantic boundary such as whitespace followed by a pause.

Snapshots without an associated completion example are still useful as past
inputs. Capture one when a field is submitted, cleared after submission, or
loses focus after meaningful edits.

## SQLite schema

All timestamps are Unix milliseconds. Text offsets use UTF-16 because macOS
Accessibility selection ranges use UTF-16.

Sensitive values use an authenticated sealed representation such as
LZFSE-compressed plaintext wrapped in AES-GCM. The encryption key lives in the
Keychain. `lookup_hmac` and content fingerprints use a separate keyed HMAC so
records can be matched without storing searchable plaintext.

```sql
PRAGMA foreign_keys = ON;

CREATE TABLE history_scope (
    id INTEGER PRIMARY KEY,
    kind TEXT NOT NULL
        CHECK (kind IN ('application', 'website')),
    lookup_hmac BLOB NOT NULL,
    value_sealed BLOB NOT NULL,
    key_version INTEGER NOT NULL,
    created_at_ms INTEGER NOT NULL,
    UNIQUE(kind, lookup_hmac)
);

CREATE TABLE input_episode (
    id TEXT PRIMARY KEY, -- UUID
    application_scope_id INTEGER
        REFERENCES history_scope(id) ON DELETE SET NULL,
    website_scope_id INTEGER
        REFERENCES history_scope(id) ON DELETE SET NULL,
    input_kind TEXT,
    started_at_ms INTEGER NOT NULL,
    ended_at_ms INTEGER,
    end_reason TEXT
        CHECK (
            end_reason IS NULL OR end_reason IN (
                'focus_changed',
                'submitted',
                'cleared',
                'app_terminated',
                'unknown'
            )
        )
);

CREATE TABLE input_snapshot (
    id INTEGER PRIMARY KEY,
    episode_id TEXT
        REFERENCES input_episode(id) ON DELETE CASCADE,
    captured_at_ms INTEGER NOT NULL,
    capture_reason TEXT NOT NULL
        CHECK (capture_reason IN (
            'before_accepted_suggestion',
            'before_typed_burst',
            'submitted',
            'focus_lost',
            'periodic'
        )),

    -- The complete field value. It is never truncated for persistence.
    field_text_sealed BLOB NOT NULL,
    field_text_hmac BLOB NOT NULL,
    field_utf16_length INTEGER NOT NULL,

    selection_start_utf16 INTEGER NOT NULL,
    selection_length_utf16 INTEGER NOT NULL DEFAULT 0,
    key_version INTEGER NOT NULL,

    CHECK (field_utf16_length >= 0),
    CHECK (selection_start_utf16 >= 0),
    CHECK (selection_length_utf16 >= 0),
    CHECK (
        selection_start_utf16 + selection_length_utf16
        <= field_utf16_length
    )
);

CREATE INDEX input_snapshot_episode_time
    ON input_snapshot(episode_id, captured_at_ms);

CREATE INDEX input_snapshot_content
    ON input_snapshot(field_text_hmac);

CREATE TABLE completion_example (
    id INTEGER PRIMARY KEY,
    snapshot_id INTEGER NOT NULL
        REFERENCES input_snapshot(id) ON DELETE CASCADE,
    source TEXT NOT NULL
        CHECK (source IN ('user_typed', 'accepted_suggestion')),

    -- Exact inserted slice. Leading/trailing whitespace is significant.
    insertion_text_sealed BLOB NOT NULL,
    insertion_hmac BLOB NOT NULL,
    insertion_utf16_length INTEGER NOT NULL,

    acceptance_scope TEXT
        CHECK (
            acceptance_scope IS NULL OR acceptance_scope IN (
                'next_word',
                'entire_suggestion'
            )
        ),

    pair_hmac BLOB NOT NULL,
    created_at_ms INTEGER NOT NULL,
    last_retrieved_at_ms INTEGER,
    retrieval_count INTEGER NOT NULL DEFAULT 0,
    eligible_for_prompt INTEGER NOT NULL DEFAULT 1
        CHECK (eligible_for_prompt IN (0, 1)),

    CHECK (insertion_utf16_length > 0),
    CHECK (
        (source = 'accepted_suggestion' AND acceptance_scope IS NOT NULL)
        OR
        (source = 'user_typed' AND acceptance_scope IS NULL)
    )
);

CREATE INDEX completion_example_pair
    ON completion_example(pair_hmac);

CREATE INDEX completion_example_created
    ON completion_example(created_at_ms DESC);

CREATE TABLE embedding_model (
    id TEXT PRIMARY KEY,
    dimensions INTEGER NOT NULL,
    scalar_type TEXT NOT NULL
        CHECK (scalar_type IN ('float16', 'float32')),
    normalized INTEGER NOT NULL DEFAULT 1
        CHECK (normalized IN (0, 1)),
    maximum_tokens INTEGER NOT NULL,
    created_at_ms INTEGER NOT NULL
);

CREATE TABLE example_embedding (
    example_id INTEGER NOT NULL
        REFERENCES completion_example(id) ON DELETE CASCADE,
    model_id TEXT NOT NULL
        REFERENCES embedding_model(id) ON DELETE CASCADE,

    -- The canonical field remains whole. These offsets identify a derived
    -- rolling window within the pre-insertion prefix.
    window_kind TEXT NOT NULL
        CHECK (window_kind IN ('cursor_tail', 'document_chunk')),
    window_index INTEGER NOT NULL DEFAULT 0,
    window_start_utf16 INTEGER NOT NULL,
    window_end_utf16 INTEGER NOT NULL,
    window_hmac BLOB NOT NULL,

    vector_sealed BLOB NOT NULL,
    dimensions INTEGER NOT NULL,
    scalar_type TEXT NOT NULL
        CHECK (scalar_type IN ('float16', 'float32')),
    key_version INTEGER NOT NULL,
    created_at_ms INTEGER NOT NULL,

    PRIMARY KEY (
        example_id,
        model_id,
        window_kind,
        window_index
    ),
    CHECK (window_start_utf16 >= 0),
    CHECK (window_end_utf16 > window_start_utf16)
);

CREATE INDEX example_embedding_model
    ON example_embedding(model_id, window_kind);

CREATE TABLE history_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

`pair_hmac` covers the example source, complete field value, cursor/selection,
and exact insertion. It supports duplicate-frequency scoring without exposing
text. It is intentionally indexed but not unique so repeated use remains an
observable signal.

## Rolling windows

The full field is canonical. Windows are disposable derived data.

Start with one `cursor_tail` embedding per example:

- Take the prefix ending at `selection_start_utf16`.
- Keep at most the embedding model's last 384 tokens.
- Move the start forward to a word, sentence, or newline boundary when
  practical.
- Do not include the insertion in its own retrieval embedding.
- For a mid-line insertion, optionally append up to 64 tokens of suffix under a
  stable separator when both query and stored examples use the same format.

The current input uses the identical projection before embedding. Query against
stored `cursor_tail` vectors with cosine similarity.

If long-input retrieval later misses important document-level context, add
overlapping `document_chunk` embeddings without changing the canonical schema:

- 384-token chunks.
- 64-token overlap.
- Score the best matching chunk separately from the cursor-tail match.
- Keep cursor-tail similarity dominant because it describes the text that
  immediately caused the insertion.

Do not persist a separately truncated `input_text` column. Window offsets and
the full field allow windows to be regenerated when the embedding model or
window policy changes.

## Retrieval and ranking

Retrieve more candidates than the prompt can hold, then rerank and diversify.
A first scoring model can use:

```text
score =
  0.65 * cursor_tail_cosine_similarity +
  0.12 * same_application +
  0.08 * same_website +
  0.05 * same_input_kind +
  0.05 * recency_decay +
  0.05 * log1p(duplicate_pair_count)
```

Apply a provenance multiplier after the base score:

```text
user_typed          1.00
accepted_suggestion 0.90
```

These weights are experimental, not schema. Keep them in configuration so
quality fixtures can compare direct writing, accepted suggestions, and mixed
retrieval.

Before prompt injection:

- Remove exact duplicate pairs.
- Avoid multiple examples with near-identical inputs.
- Reject empty, secure, excluded-app, or policy-ineligible records.
- Prefer examples whose insertion boundary matches the current boundary:
  partial word, word preceded by whitespace, or punctuation.
- Cap the block by both example count and tokens; begin with four examples or
  320 tokens, whichever comes first.

## Prompt rendering

Store raw fields, not preformatted prompt strings. Rendering belongs in
`CompletionPrompt` so framing can evolve without a migration.

Insert retrieved examples after the stable literal boundary demonstrations:

```text
Task: Continue the following text from the cursor...

Literal insertion examples:
...

Relevant examples from past writing:

Text: I can take a look at that
Insertion: tomorrow

Text: this is incred
Insertion:ible

Context:
...

Text: <current input>
Insertion:
```

The renderer must concatenate the delimiter and insertion exactly:

```swift
"Insertion:" + insertion
```

It must not trim or manually prepend a space. That preserves the distinction
between `Insertion: tomorrow`, `Insertion:world`, and `Insertion:ible`.

For prompt projection:

- Use the complete prefix when it fits the per-example token budget.
- Otherwise use a rolling suffix ending at the stored cursor.
- Align truncation to a natural boundary instead of starting mid-token.
- Never mutate the canonical snapshot.
- Initially inject only end-of-field examples into the `Text:/Insertion:`
  format. Retain mid-line captures for a future cursor-marker or suffix-aware
  format rather than teaching an ambiguous continuation.

## Prompt-cache behavior

Dynamic examples can reduce prefix-cache reuse, but the damage can be bounded:

1. Keep task instructions and literal boundary demonstrations before the
   retrieved block.
2. Sort retrieved examples deterministically.
3. Hold the retrieved set stable during a typing burst.
4. Refresh only after a meaningful semantic boundary, such as sentence change,
   paragraph change, focus change, or a whitespace-triggered idle period.
5. Cache retrieval by:
   - embedding model ID,
   - HMAC of the current rolling window,
   - application and website scope,
   - retrieval-policy version.
6. Do not block inference indefinitely for retrieval. Use the last valid set or
   omit personalization if the asynchronous query misses a small latency
   budget.

The current text already changes near the end of every prompt. Stable retrieved
examples preserve cache reuse through the task, literal demonstrations,
retrieved block, and stable context. Benchmark prompt-evaluation time with zero,
two, and four retrieved examples before changing defaults.

## Privacy and retention

- Collection and prompt use are separate settings.
- Never collect secure/protected fields.
- Respect global, per-application, and per-website exclusions before capture.
- Keep database and journal files owner-only.
- Encrypt field text, insertions, scopes, and vectors at rest.
- Decrypt vectors into an in-memory index for bounded brute-force cosine search;
  do not require an unencrypted SQLite vector extension.
- Remote completion providers receive retrieved examples only after explicit
  opt-in distinct from local personalization.
- Support inspect, per-record delete, per-app delete, and delete-all.
- Use row/key versions so encryption keys can rotate.
- Enforce retention by total encrypted bytes and age, not by truncating fields.
  Evict complete old snapshots/examples as units.

## Runtime boundaries

No database or embedding work belongs in the key-event handler.

```text
Accessibility snapshot
        |
        v
in-memory HistoryCapture event
        |
        v
HistoryRecorder actor ---> encrypted SQLite
        |
        +------------> background embedding queue

current field ---> rolling-window query ---> in-memory vector index
                                      |
                                      v
                           RetrievedCompletionExample[]
                                      |
                                      v
                              CompletionPrompt
```

Portable contracts belong in `CompletionCore`:

- `HistoryCapture`
- `CompletionExample`
- `RetrievedCompletionExample`
- `HistoryStore` protocol
- retrieval and ranking policy
- prompt rendering

The macOS target owns:

- reading the complete Accessibility field and selection,
- secure-field and per-app policy checks,
- Keychain access,
- encrypted SQLite implementation,
- local embedding-model lifecycle.

The existing `onSuggestionAccepted(String)` callback is insufficient. Replace
it with a structured capture containing the complete pre-insertion field,
selection range, exact accepted slice, acceptance scope, and app/input metadata.
Send that value asynchronously to the recorder actor.

## Implementation slices

1. Add portable capture/example types and the migration runner.
2. Extend `EditorSnapshot` with complete field text and selection range.
3. Record accepted-suggestion examples asynchronously, with no retrieval yet.
4. Record finalized full inputs and aggregated user-typed bursts.
5. Add Keychain-backed row encryption and deletion controls.
6. Add a local embedding adapter and background `cursor_tail` embeddings.
7. Add deterministic retrieval and prompt injection behind the existing Input
   History toggle.
8. Add Prompt Lab visibility into retrieved examples and token cost.
9. Benchmark quality, TTFT, prompt-evaluation time, and cache hit behavior
   before enabling collection or retrieval by default.
