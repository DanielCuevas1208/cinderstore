# Cinderstore roadmap

Statuses use `complete`, `in progress`, `planned`, or `blocked`.

## Complete

### compaction-budget — complete

User-visible outcome: operators can limit maintenance work between calls.

Bounded deliverable: resumable full-compaction slices with manifest markers.

Acceptance criteria:

- A positive `compaction_work_budget` bounds merged keys per slice.
- A marker stores source tables, output tables, and the resume key.
- Restart between slices preserves values and tombstones.
- Snapshots keep the same rows while slices run.
- Final output matches uninterrupted compaction.

Verification command: `crystal spec spec/compaction_budget_spec.cr`.

Evidence in this release:

- GitHub Actions [run 36](https://github.com/DanielCuevas1208/cinderstore/actions/runs/41429567155) passed on Ubuntu and Windows.
- The run checks formatting, the full spec suite, both demos, and the production build.
- The deterministic spec covers restarts, updates, and tombstones.
- The demo reports restart slices and a deleted key.

### compaction-observability — complete

Outcome: operators can inspect per-level bytes and compaction amplification.

Deliverable: `DB#stats` reports input and output tables, entries, and bytes.

Acceptance: deterministic overwrite and delete work reconciles counters with
produced table files.

Verification command: `crystal spec spec/compaction_spec.cr`.

### release-0.16 — complete

Bounded exact and range index queries work over the local protocol.

### release-0.15 — complete

Limits apply to primary scans, index queries, snapshots, and CLI reads.

### release-0.14 — complete

Index backfills support existing rows. JSON definitions survive restart and export.

### release-0.13 — complete

Snapshot export copies live rows into a new database directory.

### release-0.12 — complete

The local protocol streams bounded primary range and prefix scans.

### release-0.11 — complete

Read-only verification covers tables, WALs, and manifest metadata.

### release-0.10 — complete

Primary prefix scans share one ordered merge path.

### release-0.09 — complete

Primary range iterators provide snapshot-consistent streaming reads.

### release-0.08 — complete

Secondary index queries stream through local iterators and the server.

### release-0.07 — complete

Secondary indexes share WAL, sorted tables, compaction, and recovery.

### release-0.06 — complete

Batch writes and group commit provide atomic records and shared durability syncs.

### release-0.05 — complete

Optional checksums support a documented fast write mode.

### release-0.04 — complete

Level-based compaction cascades tables and retains tombstones at deeper levels.

### release-0.03 — complete

Snapshots and snapshot iterators provide consistent reads during compaction.

## In progress

### index-build-progress — in progress

User-visible outcome: operators can inspect and resume JSON index backfills.

Bounded deliverable: persisted primary-key cursors with one configurable batch per call.

Acceptance criteria:

- `start_json_index` persists a building status and a primary-key cursor.
- `build_index` processes at most `index_build_batch_size` live primary rows.
- Queries and snapshot queries reject incomplete indexes.
- Restart resumes the stored cursor.
- Concurrent writes remain indexed and finished results match a primary scan.

Verification command: `crystal spec spec/index_build_progress_spec.cr`.

Evidence in this release:

- `crystal tool format --check` passes.
- No-codegen type checks pass for the CLI, both demos, and all spec files.
- The deterministic spec covers query gating, restart recovery, and writes between slices.
- The demo includes a three-batch catalog walkthrough and matching README output.

Verification blocker: the Windows sandbox denies Crystal linker pipes.
The executable spec run remains pending in this environment.

## Planned

### index-build-cli — planned

User-visible outcome: operators can resume and inspect index builds without embedding Crystal code.

Bounded deliverable: CLI commands for index status and one JSON index build batch.

Acceptance criteria:

- Status prints name, state, processed rows, and last key.
- Build runs one configured batch and returns a non-ready exit code when work remains.
- Restart and query-gating behavior match the library API.

Verification command: `crystal spec spec/index_build_cli_spec.cr`.

### level-compaction-budget — planned

User-visible outcome: background level compaction yields between bounded slices.

Bounded deliverable: apply persisted work budgets to `compact_levels`.

Acceptance: restart preserves level placement, values, and tombstones.

Verification command: `crystal spec spec/level_compaction_budget_spec.cr`.
