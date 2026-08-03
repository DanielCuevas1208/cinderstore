# Roadmap

Cinderstore ships one coherent release at a time. Each release keeps the
public API stable. Each release passes the full test suite.

## Delivered

- Release 0.3: snapshot iterators and consistent reads. A snapshot gives
  a stable view of the store. Compaction keeps referenced files alive.
- Release 0.4: optional checksum-free fast mode. The store can skip CRC32
  work for faster reads and writes.

## Planned

- Release 0.5: batch writes and group commit. Group writes into one
  fsync.
- Release 0.6: secondary indexes. Look up rows by any indexed value.
- Release 0.7: incremental compaction by level. Merge only the tables
  that overlap.

## Status

- Snapshots: complete and tested.
- Checksum-free fast mode: complete and tested.
- Batch writes: not started.
- Secondary indexes: not started.
- Incremental compaction: not started.
