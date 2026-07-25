# Completion episodes

StenoTab records one completion episode for each model suggestion that becomes
visible to the user. This is separate from a writing episode, which describes
the longer period spent editing one field.

## Captured data

A completion episode preserves:

- the full editor value and UTF-16 selection used for the request (for a
  prefetched refill, the speculative post-acceptance field that must match the
  real editor before the refill can be presented);
- the exact text prompt or chat messages sent by the provider;
- context already composed into that model input, including OCR or clipboard
  content when those Prompt Lab components are enabled;
- provider kind, model identifier, credential-free endpoint origin, token
  limit, temperature, and stop strings;
- every distinct sanitized suggestion revision exposed by streaming;
- every literal partial or full acceptance span and its acceptance scope;
- text typed through an exactly matching suggestion;
- whether generation failed after producing a usable partial suggestion;
- the final full editor value when the suggestion is resolved;
- the literal replacement/continuation inferred at the original selection;
- resolution such as accepted, partially accepted, typed through, rejected, or
  superseded; and
- application, website, input-kind, language, editor, and timestamps.

Accepted-suggestion events carry the originating completion-episode ID.
Immediate reversion feedback already points to the accepted-suggestion event,
so the corpus can trace a later deletion back to the model invocation that
produced it.

Cancelled requests that never expose a suggestion are not retained. Prefetched
refills become episodes only when StenoTab actually presents them.
When retained prompt examples or a periodic voice assessment come from earlier
events, the completion episode records those source-event dependencies and
source scopes. Deleting or expiring a source event, or deleting its application
history, also removes any episode whose stored prompt copied or summarized that
source text.

Storage formats from before source-lineage capture are removed once on upgrade.
Their copied prompt dependencies cannot be reconstructed safely, so retaining
those records would make source and per-application deletion incomplete.

## Storage and use

Completion episodes use the existing encrypted personalization event ledger.
SQLite does not contain searchable prompt, editor, OCR, clipboard, suggestion,
or outcome text.

Large text is not copied into every sealed event. StenoTab splits field and
prompt text into small AES-GCM-sealed chunks addressed by keyed HMACs. Prompt
paragraphs are chunked independently, and the prompt reuses the input-prefix
chunks when possible. Unchanged chunks are therefore stored once even when a
long field appears in many consecutive requests. The database reveals opaque
chunk reuse/reference relationships, opaque source-event dependency
relationships, and the exact plaintext UTF-8 byte count of each short or final
chunk, but neither its plaintext nor an unkeyed content hash. Source
relationships, chunk reachability, application scopes, and retention
timestamps are rebuilt from authenticated payloads before relevant deletion,
so plaintext secondary indexes are not trusted as deletion authorities.

Stream revisions and the final field are stored as reversible text deltas.
Reading, inspection, and export hydrate these references back into the exact
`CompletionEpisodeCapture` shape; consumers do not need to understand the
storage representation. Deleting or expiring an episode garbage-collects only
chunks no remaining episode references. The configured encrypted-byte
retention cap includes this shared chunk store.
SQLite full secure deletion overwrites deleted encrypted rows and chunks so
their ciphertext cannot be recovered from free database pages with the
Keychain key still present.

These records are available in readable JSON export, retention enforcement,
per-record deletion, per-application deletion, and Delete All. Recent outcomes
are inspectable in **Settings → Personalization**, including an expandable
view of the exact model input.

Completion episodes do not currently feed prompt retrieval, vocabulary
ranking, or voice assessment. Existing accepted-suggestion and writing-episode
events remain the canonical inputs for classical personalization, avoiding
duplicate evidence and model self-reinforcement.

The optional QLoRA subsystem may consume eligible completion episodes later.
Its incremental training and adapter-lineage requirements are documented in
the repository-root `TODO.md`.
