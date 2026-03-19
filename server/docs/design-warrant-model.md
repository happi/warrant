# Warrant Object Model

## Core Distinction: Intent Source vs Warrant

A **task** or **issue** is not a warrant. It is an **intent source** — a pre-work
artifact that describes *why* a change should exist before the code is written.

A **warrant** is a first-class decision object created at **merge time** that binds:

- One or more intent sources (the "why")
- The merged code (the "what")
- Approvals and authorization (the "who approved")
- Traceability metadata (the "when" and "where")

The invariant: **no code reaches main without being resolvable to a warrant.**

## Why Warrants Are Created at Merge Time

In distributed and open-source workflows, we cannot reliably create a final
warrant before implementation starts:

- There is no central allocator for warrant numbers
- We do not want coordination bottlenecks
- Intent may evolve during implementation
- Multiple intent sources may converge into a single change
- We only know what actually landed after merge

At merge time we know:

1. What commits were accepted
2. Who reviewed and approved
3. Which intent sources were referenced
4. The final shape of the change

This is when the warrant becomes real.

## Why Content-Addressed IDs

Sequential warrant numbers (W-1, W-2, ...) require:

- A central counter service
- Online coordination for every warrant
- Race condition handling for concurrent merges
- Trust in the counter service

Content-addressed IDs eliminate all of these:

```
warrant_id = hex(sha256(canonical_warrant_content))
```

Properties:

1. **No central allocator needed** — any node can produce the ID
2. **Deterministic** — same content always gives the same ID
3. **Tamper-evident** — any material change produces a new ID
4. **Self-verifying** — the ID IS the integrity check
5. **Offline-compatible** — no network needed to compute
6. **Append-only friendly** — fits ledger-style traceability

Human-friendly aliases (short prefixes, project-scoped names) can be layered
on top. The ground truth is always the content hash.

## Domain Model

### IntentSource

Pre-work artifact from an external system.

```
IntentSource {
    id            : "backlog:HL-131" | "github:happi/warrant#42"
    source_type   : "backlog" | "github" | ...
    source_ref    : "HL-131" | "42"          (ID in the source system)
    title         : text
    body          : text | null
    author        : text | null
    labels        : [text]
    metadata      : {}                        (source-specific)
    created_at    : ISO 8601
    updated_at    : ISO 8601
}
```

The `id` field is `<source_type>:<source_ref>` — stable, unique across plugins.
For GitHub issues that include repo context: `github:<owner>/<repo>#<number>`.

### MergeContext

The facts of a merge event.

```
MergeContext {
    commits       : [sha]                     (sorted lexicographically)
    merge_commit  : sha | null                (the merge commit itself)
    pr_number     : text | null
    pr_url        : text | null
    pr_title      : text | null
    repository    : "owner/repo"
    target_branch : "main"
    actor         : text                      (who merged)
    reviewers     : [text]                    (sorted)
    approvals     : [text]                    (sorted, subset of reviewers)
    merged_at     : ISO 8601
}
```

### Warrant

The merge-time decision object.

```
Warrant {
    warrant_id        : hex(sha256(canonical_content))
    summary           : text
    intent_sources    : [IntentSourceRef]      (id, source_type, source_ref, title)
    merge             : MergeContext
    canonical_content : JSON text              (the exact bytes that were hashed)
    created_at        : ISO 8601
    org_id            : text | null
    project_id        : text | null
    metadata          : {}
}
```

## Canonical Serialization

The warrant ID is derived from a canonical JSON representation.

### Rules

1. All object keys sorted lexicographically
2. All string arrays sorted lexicographically
3. Arrays of objects sorted by the `id` field
4. Compact JSON (no whitespace)
5. Null values omitted (key not present)
6. Empty arrays omitted (key not present)
7. Empty strings omitted (key not present)
8. Timestamps in ISO 8601 UTC with `Z` suffix
9. Schema version field for future evolution

### Canonical Structure

```json
{
  "intent_sources":[
    {"id":"backlog:HL-131","source_ref":"HL-131","source_type":"backlog","title":"Fix week number"}
  ],
  "merge":{
    "actor":"happi",
    "approvals":["reviewer1"],
    "commits":["abc123...","def456..."],
    "merged_at":"2026-03-19T10:00:00Z",
    "pr_number":"42",
    "pr_title":"HL-131: Fix week number display",
    "repository":"happi/home_display",
    "reviewers":["reviewer1"],
    "target_branch":"main"
  },
  "summary":"Fix week number display in home_display header",
  "version":1
}
```

Then: `warrant_id = lowercase_hex(sha256(canonical_json))`

### Hash Function

SHA-256 is the default. The `version` field allows migrating to a different
hash in the future while keeping old warrants verifiable.

## Intent Source Plugins

Each plugin implements a common interface:

```
source_type() -> binary
extract_refs(Text, Config) -> [binary]        (find references in text)
fetch(SourceRef, Config) -> IntentSource       (resolve a reference)
```

### backlog.md Plugin

- Parses task files from `backlog/tasks/*.md`
- ID format: `backlog:<TASK-ID>` (e.g., `backlog:HL-131`)
- Reference pattern: `[A-Z]+-\d+` in branch names, commits, PR body
- Falls back to `backlog:<filepath>` for tasks without explicit IDs

### GitHub Issues Plugin

- Fetches issue metadata from GitHub API or webhook payloads
- ID format: `github:<owner>/<repo>#<number>` (e.g., `github:happi/warrant#42`)
- Reference patterns: `#\d+`, `owner/repo#\d+`, `Fixes #\d+`, `Closes #\d+`

## Merge-Time Flow

```
1. PR merged (webhook or manual trigger)
2. Extract text from: branch name, commit messages, PR title, PR body
3. Run each plugin's extract_refs() on the text
4. Deduplicate references
5. For each reference, call plugin's fetch() to get IntentSource
6. Build MergeContext from PR metadata
7. Build canonical warrant content
8. Hash to produce warrant_id
9. Persist warrant + link to intent sources + link to commits
```

## Example Scenarios

### 1. Backlog task -> PR -> merge -> warrant

Developer creates backlog task `HL-131`, works on branch `task/HL-131-fix-week`,
commits reference `HL-131: ...`, PR is merged.

Extracted refs: `["HL-131"]`
Intent source: `{id: "backlog:HL-131", title: "Fix week number..."}`
Warrant ID: `sha256(canonical_json)` = `a7f3b2...`

### 2. GitHub issue -> PR -> merge -> warrant

Issue `#42` exists. PR body says `Fixes #42`. PR is merged.

Extracted refs: `["42"]`
Intent source: `{id: "github:happi/warrant#42", title: "Login page broken"}`
Warrant ID: `sha256(canonical_json)` = `e1c9d4...`

### 3. Multiple intent sources

Branch: `task/HL-131-fix-stuff`, PR body: `Also addresses #42`.

Extracted refs: `["HL-131", "42"]`
Intent sources: `[backlog:HL-131, github:happi/warrant#42]`
Single warrant with both sources.

### 4. Missing intent reference

PR merged with no task/issue references found in branch, commits, or PR body.

Options (configurable policy):
- **warn**: create warrant with empty intent_sources, flag for review
- **block**: reject merge (CI check fails)
- **exempt**: allow specific patterns (e.g., `chore/*` branches)

## Future Directions

- Deploy manifests that list included warrant IDs
- CI policy: every PR must reference at least one intent source
- Warrant chain: link warrants that supersede previous ones
- Cross-repo warrants: a change spanning multiple repositories
- Warrant signing: cryptographic signatures from approvers
