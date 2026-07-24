# Local vocabulary and retrieval design

> This document covers the smaller derived vocabulary index. Complete
> textarea/input snapshots, accepted-suggestion examples, rolling embedding
> windows, and prompt injection are specified in
> `LOCAL_HISTORY_RETRIEVAL.md`.

## Goal

Make completions sound like the user without uploading a writing history, retraining a model, or adding database work to the keystroke path.

The first useful version should learn spelling, names, recurring phrases, and app-specific terminology. Embedding retrieval is a later ranking signal, not a prerequisite.

## Privacy boundary

- Store derived vocabulary and short accepted phrases, not complete text fields.
- Never learn from secure fields, password-like fields, or explicitly excluded apps.
- Keep the database in the app's Application Support directory with owner-only file permissions.
- Provide pause, per-app exclusion, inspect/export, and delete-all controls.
- Do not send learned entries to a remote completion provider unless the user explicitly enables personalization for that provider.

## Signals

Positive signals:

- A completion accepted with Tab.
- A visible completion typed exactly by the user.
- A word or short phrase used repeatedly across separate sessions.

Negative signals:

- A completion dismissed by diverging input.
- A completion repeatedly shown but never accepted.

Do not persist surrounding private prose merely to retain these counters.

## Hot-path architecture

1. Keystrokes update the existing in-memory shadow buffer.
2. An in-memory accumulator observes completed tokens and completion outcomes.
3. A background actor batches SQLite writes every 30 seconds and on clean shutdown.
4. Before inference, a read-only snapshot performs bounded lexical retrieval.
5. Retrieved items either augment the prompt in a small `Personal vocabulary` section or rerank generated candidates.

No SQLite write, embedding calculation, or filesystem sync occurs synchronously between a key event and showing ghost text.

## SQLite schema

```sql
CREATE TABLE vocabulary_item (
    id INTEGER PRIMARY KEY,
    normalized_text TEXT NOT NULL,
    display_text TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('word', 'phrase')),
    app_scope TEXT,
    use_count INTEGER NOT NULL DEFAULT 0,
    accepted_count INTEGER NOT NULL DEFAULT 0,
    rejected_count INTEGER NOT NULL DEFAULT 0,
    first_seen_at REAL NOT NULL,
    last_seen_at REAL NOT NULL,
    UNIQUE(normalized_text, kind, app_scope)
);

CREATE VIRTUAL TABLE vocabulary_fts USING fts5(
    normalized_text,
    display_text,
    content='vocabulary_item',
    content_rowid='id'
);

CREATE TABLE embedding (
    vocabulary_item_id INTEGER PRIMARY KEY
        REFERENCES vocabulary_item(id) ON DELETE CASCADE,
    model_id TEXT NOT NULL,
    dimensions INTEGER NOT NULL,
    vector BLOB NOT NULL,
    l2_norm REAL NOT NULL,
    updated_at REAL NOT NULL
);

CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

`app_scope` is nullable: global vocabulary has `NULL`; terms strongly associated with one bundle identifier receive an app-scoped row.

## Retrieval stages

Run inexpensive, deterministic stages first:

1. Exact prefix and recent-use lookup.
2. FTS5 prefix retrieval.
3. Frequency/recency/acceptance scoring.
4. Optional semantic reranking over at most the top 100 lexical candidates.

A practical score:

```text
score =
  3.0 * prefix_match +
  1.5 * log1p(use_count) +
  2.0 * acceptance_rate +
  1.0 * recency_decay +
  1.0 * app_scope_match -
  1.5 * rejection_rate
```

The result is capped to roughly 20 words or five phrases so personalization cannot crowd out the actual cursor context.

## Embeddings

Embeddings help retrieve semantically related phrases, but they are unnecessary for names and spelling. Add them only after lexical retrieval is measured.

- Generate embeddings asynchronously while idle.
- Version rows by `model_id`; never mix vector spaces.
- For a small personal corpus, decode vectors from SQLite and brute-force cosine similarity over the lexical shortlist.
- Consider `sqlite-vec` only if the corpus grows enough to justify another native dependency.
- Local embedding models are the default. Remote embeddings require separate explicit consent.

## Retention and controls

- Default cap: 10,000 words and 2,000 phrases.
- Evict low-frequency, old, never-accepted entries first.
- Phrase length: 2–8 tokens; reject strings containing URLs, email addresses, or long digit sequences.
- Expose a vocabulary inspector with search, delete, pin, and per-app scope.
- “Delete learned vocabulary” removes the SQLite database and in-memory accumulator.

## Implementation slices

1. SQLite migrations plus batched word/phrase counters.
2. FTS5 lexical retrieval and prompt injection behind a feature flag.
3. Acceptance/rejection feedback and per-app scoping.
4. Vocabulary inspector and deletion controls.
5. Optional local embeddings and semantic reranking, justified by benchmarks.
