# Changelog

Cinderstore follows a numbered release track. Each release keeps the on-disk
format compatible with earlier releases.

## 0.4.0 - 2026-08-03

Added the optional checksum-free fast mode.

- Add the `checksums` config option. It defaults to `true`.
- Skip CRC32 work on writes and reads when the option is off.
- Record the checksum mode in the table footer and the WAL header.
- Read version 1 tables and logs from release 0.3 unchanged.
- Report the durable checksum mode through `stats`.
- Add the `--no-checksums` flag to the command line tool.
- Add 12 tests for the checksum-free mode.

## 0.3.0 - 2026-08-03

Added point-in-time snapshots.

- Create an immutable snapshot with `snapshot`.
- Keep snapshot reads consistent while the store keeps writing.
- Keep compacted table files alive until snapshots release them.
- Add snapshot iterators and range scans.
