# Cinderstore

[![CI](https://github.com/DanielCuevas1208/cinderstore/actions/workflows/ci.yml/badge.svg)](https://github.com/DanielCuevas1208/cinderstore/actions/workflows/ci.yml)

Cinderstore is an embeddable key and value store. It is built on a log
structured merge tree (LSM tree). It is written in Crystal and uses only the
Crystal standard library.

The store keeps a write ahead log for durability. It flushes memory to sorted
files. It merges those files during compaction. It recovers all data after a
restart. It serves `get`, `put`, and `delete` over a local socket.

Snapshots give you a consistent view of the store at one instant. A snapshot
never blocks new writes. Release it when you are done.

This is release 0.4.0. It adds leveled compaction. Compaction now moves one
level at a time instead of rewriting every table.

## Features

- Memory table with ordered writes
- Durable write ahead log with CRC32 framing
- Sorted tables with a block index and a bloom filter
- Block cache for fast repeated reads
- Background flush and compaction
- Leveled compaction that moves one level at a time
- Tombstones that drop only at the deepest level
- Point-in-time snapshots with consistent reads
- Snapshot iterators that stay valid during writes
- Range scans with an iterator API
- Crash recovery from the write ahead log
- Local TCP server with a line protocol
- Zero runtime dependencies

## Quick start

You need Crystal 1.10 or newer.

```console
crystal spec
crystal run examples/demo.cr
```

Cinderstore has no dependencies. It does not need `shards install`.

Build the command line tool.

```console
shards build --production
```

Run the demo.

```console
bin/cinderstore demo
```

## Demo output

The demo loads a product catalog from `fixtures/catalog.csv`. It writes,
scans, flushes, compacts, deletes, snapshots, and reopens a database. The
output is deterministic.

```text
== Cinderstore 0.4.0 demo ==

Loaded 24 products from ...\fixtures\catalog.csv
Database directory: ...\cinderstore-demo

1. Writes buffered in the memtable
   entries: 24, memtable bytes: 2990, tables: 0

2. Range scan SKU-0010 to SKU-0020
   SKU-0010  {"name":"Ash Rake Forged","price":14.00,"stock":31}
   SKU-0011  {"name":"Coal Shovel Small","price":19.40,"stock":22}
   SKU-0012  {"name":"Ember Tray Brass","price":52.80,"stock":15}
   SKU-0013  {"name":"Ember Poker Curved","price":17.60,"stock":40}
   SKU-0014  {"name":"Fire Tongs Dining","price":15.90,"stock":35}
   ... (24 rows in the store)

3. Flush memtable to a sorted table
   tables: 1 (l0: 1, l1: 0), entries: 24
   disk bytes: 1649, memtable bytes: 0

4. Delete 4 products, update 2 products, then flush again
   tables: 2 (l0: 2, l1: 0), entries: 30
   disk bytes: 1902, memtable bytes: 0
   The deleted keys still occupy space in the level-0 tables.

5. Compact merges the tables and drops the deleted keys
   tables: 1 (l0: 0, l1: 1), entries: 20
   disk bytes: 1384, memtable bytes: 0
   The store keeps the newest value for each key.

6. Verify deletes and updates after compaction
   get SKU-0003 => nil
   get SKU-0001 => "{\"name\":\"Forge Anvil 45kg\",\"price\":175.00,\"stock\":14}"
   scan count   => 20

7. Snapshot the store for a consistent read
   snapshot rows at creation: 20
   after 2 new writes and 1 delete, then a flush
   live rows: 21, snapshot rows: 20
   live SKU-0001    => nil
   snapshot SKU-0001 => "{\"name\":\"Forge Anvil 45kg\",\"price\":175.00,\"stock\":14}"
   snapshot iterator SKU-0010 to SKU-0016
   SKU-0010, SKU-0011, SKU-0013, SKU-0014, SKU-0015

8. Leveled compaction grows deeper levels
   Write 90 products across 3 flushes
   tables: 5 (l0: 4, l1: 1), entries: 113
   compact moved level 0 into level 1
   tables: 1 (l0: 0, l1: 1), entries: 111
   level 1 passed its target, so compact moved it to level 2
   tables: 1 (l0: 0, l1: 0, l2: 1), entries: 111

9. Reopen the database and verify recovery
   rows after restart: 111

Demo complete.
```

Step 7 shows the value of a snapshot. The live store drops SKU-0001 and adds
two products. The snapshot still sees the state before those writes.

Step 8 shows leveled compaction. Three flushes pile up level 0. One compact
merges them into level 1. The level passes its target. The next compact moves
it to level 2.

## Use the library

Require the library.

```crystal
require "cinderstore"
```

Open a database and use it.

```crystal
db = Cinderstore::DB.new("data/my-store")
db.put("forge-hammer", "steel")
db.get("forge-hammer") # => "steel"
db.delete("forge-hammer")
db.scan("a", "z").each do |key, value|
  puts "#{key} => #{value}"
end
db.close
```

### Read a snapshot

A snapshot is a consistent view at one instant. Take a snapshot, read it,
then release it.

```crystal
snap = db.snapshot
snap.get("forge-hammer") # => "steel"
snap.scan("a", "z").each do |key, value|
  puts "#{key} => #{value}"
end
snap.release
```

The block form releases the snapshot automatically.

```crystal
db.snapshot do |snap|
  count = snap.count
end
```

Iterate a snapshot with a snapshot iterator. The iterator stays valid while
the database keeps writing. Close the iterator before you release the
snapshot.

```crystal
snap = db.snapshot
iter = snap.iter("SKU-0100")
while entry = iter.next?
  process(entry.key, entry.value)
end
iter.close
snap.release
```

Iterate a range with a block.

```crystal
db.each("SKU-0100", "SKU-0200") do |key, value|
  process(key, value)
end
```

Flush and compact explicitly.

```crystal
db.flush    # Move the memtable into a table.
db.compact  # Merge one level into the level below.
```

## Command line tool

The tool uses a database directory. The default directory is
`cinderstore-data`.

Write a value.

```console
bin/cinderstore put --key forge-hammer --value steel
```

Read a value.

```console
bin/cinderstore get --key forge-hammer
```

Delete a key.

```console
bin/cinderstore del --key forge-hammer
```

Scan a range.

```console
bin/cinderstore scan --start a --finish z --limit 100
```

Show counters.

```console
bin/cinderstore stats
```

Start the local server.

```console
bin/cinderstore server --db data --port 7654
```

Run `bin/cinderstore help` for the full list of commands.

## Wire protocol

The server listens on `127.0.0.1:7654` by default. Commands are lines of
text. A command ends with a newline. Keys must not contain spaces or
newlines. Values must not contain newlines.

| Command | Meaning |
| --- | --- |
| `PUT key value` | Write a value |
| `GET key` | Read a value |
| `DEL key` | Delete a key |
| `SCAN start finish limit` | List a range |
| `STATS` | Show counters |
| `PING` | Check the server |
| `FLUSH` | Flush the memtable |
| `COMPACT` | Compact the tables |
| `SHUTDOWN` | Stop the server |

The server answers with one line per command.

- `OK` for a successful write
- `VALUE value` for a read
- `NOT_FOUND` for a missing key
- `ROW key value` for each scan result, then `END`
- `STATS {...}` for the counters
- `ERR message` for an error

Use a tool such as `nc` or the included example client.

```console
printf "PUT forge-hammer steel\nGET forge-hammer\n" | nc 127.0.0.1 7654
```

## Architecture

The database stores data in a single directory. The directory contains a
manifest, one write ahead log, and sorted tables.

### Write path

A write goes to two places at once.

1. Append the entry to the write ahead log.
2. Insert the entry into the memory table.

The default mode fsyncs after every write. Set `sync_writes` to `false` for
faster, less durable writes.

### Flush

When the memory table grows past its limit, the database freezes it. A new
memory table starts. A background task writes the frozen table to a sorted
file. The old log is deleted only after the file is durable.

### Compaction

Compaction works one level at a time. Level zero holds recent flushes. Its
tables may overlap. Every deeper level holds tables that do not overlap.

A compact moves one level into the level below. It merges the source tables
with the tables below that overlap them. The merge keeps the newest entry
for each key. It writes the result to the level below.

Level zero compacts when it holds several tables. A deeper level compacts
when its size passes the level target. The level target grows by a fixed
ratio at each level.

A tombstone flows down through the levels. It is dropped only when it
reaches the deepest level. Deeper tables can hold older values. An early
drop could resurrect a deleted key.

New writes continue into the memory table during the merge. Compaction keeps
a table file on disk while a snapshot references it. The file is deleted
only after the last snapshot releases it.

### Snapshots

A snapshot is an immutable view of the store at one instant. Creation copies
the active memory table and takes a reference to each table file.

Writes, flushes, and compactions after the snapshot do not change what the
snapshot sees. The snapshot reads the table files it holds, so compaction
can replace those files without breaking the snapshot.

Snapshots never block writes. Reads over a snapshot use the same merge path
as normal reads. Release a snapshot when you are done with it.

### Read path

A read merges the memory table, any frozen table, and all sorted tables. The
merge yields the newest entry for each key. The bloom filter lets a reader
skip a table that cannot contain the key. The block cache holds decoded
blocks so repeated reads avoid disk.

### Recovery

On open, the database replays the write ahead log into the memory table.
Recovery is idempotent. A torn tail is detected by its CRC32 and skipped.
The manifest lists every table. Orphan files from a crash are removed.

## On-disk format

Tables use a compact binary format.

- Data blocks hold serialized entries.
- A block index maps the first key of each block to its offset.
- A bloom filter covers every key in the table.
- A footer stores offsets, a version, and a CRC32.
- Each block and each log record carries a CRC32.

Sequence numbers make versions unique. They are per-write and never reused.

## Configuration

Tune the database with `Cinderstore::DB::Config`.

```crystal
config = Cinderstore::DB::Config.new
config.block_size = 4096
config.memtable_limit = 4_i64 * 1024 * 1024
config.bloom_fpp = 0.01
config.cache_blocks = 512
config.sync_writes = true
config.l0_compact_threshold = 4
config.compact_on_flush = true
config.level_target_bytes = 8_i64 * 1024 * 1024
config.level_ratio = 10
config.max_levels = 7
db = Cinderstore::DB.new("data", config)
```

`level_target_bytes` sets the size that triggers a level-one compact. Every
deeper level has a target that is `level_ratio` times larger. `max_levels`
caps the total number of levels.

## Project layout

```text
src/cinderstore.cr       Library entry point
src/cinderstore/         Core components
src/cinderstore/db.cr    Database and leveled compaction
src/cinderstore/snapshot.cr  Point-in-time snapshot support
src/cli.cr               Command line tool
examples/demo.cr         Library walkthrough
examples/server_demo.cr  Wire protocol walkthrough
fixtures/catalog.csv     Sample product catalog
spec/                    Test suite
```

## Test status

The suite runs with `crystal spec`. It has 106 examples. All pass on Windows
and Linux. It covers the skip list, the memory table, the write ahead log,
the bloom filter, and the block cache. It covers the tables, the iterators,
and the database. It covers durability, snapshots, and the server protocol.
It covers leveled compaction across several levels.

The CI workflow runs on GitHub Actions for Windows and Ubuntu. It checks
formatting, runs the suite, runs the demo, and builds the binary.

## Limitations

- Keys sort by byte value.
- Values are limited to 4 MB.
- Keys are limited to 4 KB.
- The server protocol is unencrypted. Use it on localhost only.
- Compaction rewrites whole levels, not single tables.
- No multi-threaded runtime is required. The server uses fibers.
- Release snapshots before you close the database.

## Roadmap

Planned:

- Release 0.5: optional checksum-free fast mode
- Release 0.6: batch writes and group commit
- Release 0.7: secondary indexes

Delivered:

- Release 0.3: snapshot iterators and consistent reads. Snapshots give a
  stable view of the store. Compaction keeps referenced files alive.
- Release 0.4: leveled compaction. Compaction moves one level at a time.
  A level compacts when it passes its size target. Tombstones drop at the
  deepest level.

## License

Cinderstore is licensed under the Apache License 2.0. See the `LICENSE` file.
