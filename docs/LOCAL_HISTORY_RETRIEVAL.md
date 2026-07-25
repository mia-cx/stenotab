# Local history and retrieved completion examples

## Current implementation

StenoTab stores a canonical encrypted event corpus and rebuildable derived
projections. The canonical record is deliberately richer than today’s prompt
or ranking policy so future retrieval experiments do not require losing or
migrating source history.

The event ledger currently records:

- accepted suggestion slices, including the complete field value, UTF-16
  cursor/selection, exact inserted whitespace, acceptance scope, timestamp,
  and context;
- complete writing episodes, including initial and final field values,
  coalesced direct-typing edits, deletions, boundaries, and context;
- exact typed-through suggestion matches; and
- immediate accepted-suggestion reversions.

Ignored suggestions are ambiguous and produce no negative signal.

All payloads and scope values are AES-GCM encrypted with a key stored in the
Keychain. Keyed HMACs permit equality lookup without searchable plaintext.
SQLite file and directory permissions are owner-only.

## Prompt examples

Retrieved examples use literal paired records:

```text
Text:
§can you open a pull req
Insertion:
§uest for this
```

The full field is retained in the canonical event. Embedding queries use only
the final 1,500 characters of the cursor prefix, and prompt composition applies
its own bounded context budget. Truncation never changes the stored source.

Two independently toggleable Prompt Lab components consume the corpus:

1. **Input history** selects up to five frecent accepted or directly typed
   examples, deduplicated by case-folded text/insertion pair. Ranking combines
   recency, repeated frequency, application, website, input kind, language,
   and accepted-suggestion provenance.
2. **Semantically relevant history** embeds the current cursor-tail using
   Apple Natural Language and ranks accepted-suggestion examples by cosine
   similarity, scope match, and recency. It excludes examples already selected
   by the frecent pass.

Directly typed examples currently participate in frecent retrieval. Semantic
indexing is limited to accepted-suggestion examples because those have an
unambiguous input/insertion boundary and stable canonical event identifier.

## Embedding storage

Each accepted event can own one embedding row:

```sql
CREATE TABLE personalization_embedding (
    event_id TEXT PRIMARY KEY
        REFERENCES personalization_event(id) ON DELETE CASCADE,
    model_identifier TEXT NOT NULL,
    dimension INTEGER NOT NULL,
    vector_sealed BLOB NOT NULL,
    created_at_ms INTEGER NOT NULL
);
```

Vectors are encrypted. Model identifier and dimension remain metadata so
StenoTab never compares vectors from different spaces. Missing rows are
backfilled by the background personalization actor at startup. Deleting a
source event cascades to its embedding.

The query vector is generated after the 45 ms debounce. This affects request
preparation latency but never executes inside the global key callback. A
cancelled debounce discards the retrieval result before inference.

## Retention and controls

Settings expose:

- stop/start collection;
- include/exclude directly typed episodes;
- high-confidence local completion;
- age and encrypted-byte caps;
- automatic voice profile and manual reassessment;
- learned-vocabulary inspection;
- recent episode and accepted-suggestion inspection;
- per-record deletion;
- per-application deletion;
- readable JSON export; and
- delete all.

Event deletion rebuilds language, retrieval, and voice projections from the
remaining canonical corpus. Website scopes are supported by storage and
ranking but remain empty until website detection is connected.

## Performance baseline

Run:

```sh
swift run -c release PersonalizationBenchmark
```

On the development Apple-silicon Mac, the 2026-07-25 warmed baseline was:

| Operation | Corpus | p50 | p95 |
| --- | ---: | ---: | ---: |
| Local phrase completion | 2,020 learned phrases | 0.022 ms | 0.022 ms |
| Apple NL query embedding | 11-word query | 3.675 ms | 5.157 ms |
| Frecent top-five retrieval | 10,000 examples | 9.090 ms | 11.091 ms |
| Semantic top-five retrieval | 2,000 × 512 dimensions | 5.505 ms | 7.552 ms |

These are microbenchmarks, not end-to-end TTFT. Their purpose is to catch local
personalization regressions before model/server latency obscures them.
