# Cinderstore roadmap

Statuses use `complete`, `in progress`, `planned`, or `blocked`.

## In progress

### compaction-budget — in progress

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

- No-codegen type checks pass for the CLI, both demos, and all spec files.
- `crystal tool format --check` passes.
- The deterministic spec covers restarts, updates, and tombstones.
- The demo reports restart slices and a deleted key.

Verification blocker: the Windows sandbox denies Crystal linker pipes and
cache writes. The executable spec run remains pending in this environment.

## Complete

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

## Planned

### index-build-progress — planned

User-visible outcome: operators can inspect index backfill progress.

Bounded deliverable: persisted batches with explicit query availability rules.

Acceptance: restart and concurrent writes match a full primary scan.

Verification command: `crystal spec spec/index_build_progress_spec.cr`.

### level-compaction-budget — planned

User-visible outcome: background level compaction yields between bounded slices.

Bounded deliverable: apply persisted work budgets to `compact_levels`.

Acceptance: restart preserves level placement, values, and tombstones.

Verification command: `crystal spec spec/level_compaction_budget_spec.cr`.
