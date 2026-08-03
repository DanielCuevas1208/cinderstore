# Cinderstore

[![CI](https://github.com/DanielCuevas1208/cinderstore/actions/workflows/ci.yml/badge.svg)](https://github.com/DanielCuevas1208/cinderstore/actions/workflows/ci.yml)

Cinderstore is an embeddable key and value store. It is built on a log
structured merge tree (LSM tree). It is written in Crystal and uses only the
Crystal standard library.

The store keeps a write ahead log for durability. It flushes memory to sorted
files. It merges those files during compaction. It recovers all data after a
restart. It serves `get`, `put`, and `delete` over a local socket.

This is release 0.2.0. Compaction now works by level. It rewrites only the
tables it must touch.

## Features

- Memory table with ordered writes
- Durable write ahead log with CRC32 framing
- Sorted tables with a block index and a bloom filter
- Block cache for fast repeated reads
- Leveled compaction that rewrites only overlapping tables
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
scans, flushes, compacts, deletes, and reopens a database. The output is
deterministic.

```text
== Cinderstore 0.2.0 demo ==

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
   tables: 1 (l0: 1), entries: 24
   disk bytes: 1649, memtable bytes: 0

4. Delete 4 products, update 2 products, then flush again
   tables: 2 (l0: 2), entries: 30
   disk bytes: 1902, memtable bytes: 0

5. Compact merges the tables and drops the deleted keys
   tables: 1 (l1: 1), entries: 20
   disk bytes: 1384, memtable bytes: 0

6. Verify deletes and updates after compaction
   get SKU-0003 => nil
   get SKU-0001 => {"name":"Forge Anvil 45kg","price":175.00,"stock":14}
   scan count   => 20

7. Reopen the database and verify recovery
   rows after restart: 20

8. Flush two disjoint ranges, then compact incrementally
   tables: 3 (l0: 2, l1: 1), entries: 30
   disk bytes: 2196, memtable bytes: 0

9. Compact cascades the merged ranges into level 2
   tables: 1 (l2: 1), entries: 30
   disk bytes: 2057, memtable bytes: 0

Demo complete.
```

Step 8 shows incremental compaction in action. Two new ranges wait in level 0.
The level-1 table stays in place. Its bytes are untouched. Step 9 cascades the
level-1 tables into a single level-2 table.

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

Iterate a range with a block.

```crystal
db.each("SKU-0100", "SKU-0200") do |key, value|
  process(key, value)
end
```

Flush and compact explicitly.

```crystal
db.flush    # Move the memtable into a table.
db.compact  # Merge tables and drop stale data.
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

Tables live in levels. Level 0 receives every flush. Its tables may overlap.
Deeper levels hold non-overlapping tables. Reads scan every level and pick the
newest entry for each key.

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

Level-0 tables may overlap. Compaction merges a level into the next level. It
rewrites only the tables that overlap. Disjoint tables stay in place.

Each merge writes fresh, non-overlapping tables. The merge keeps the newest
entry for each key. Tombstones drop only when the merge covers every older
copy. Deeper levels hold older data. New writes continue into the memory table
during the merge.

A level starts a merge when it reaches a size threshold. Level 0 uses
`l0_compact_threshold`. Deeper levels use `l1_compact_threshold`. `max_level`
bounds how deep the cascade may go.

### Read path

A read merges the memory table, any frozen table, and all sorted tables. The
merge yields the newest entry for each key. The bloom filter lets a reader
skip a table that cannot contain the key. The block cache holds decoded
blocks so repeated reads avoid disk.

### Recovery

On open, the database replays the write ahead log into the memory table.
Recovery is idempotent. The CRC32 detects a torn tail and skips it. The
manifest lists every table. The database removes orphan files from a crash.

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
config.l1_compact_threshold = 4
config.max_level = 6
config.compact_on_flush = true
db = Cinderstore::DB.new("data", config)
```

`stats` reports a table count per level. The server returns these counts in
the `STATS` response as the `levels` array.

## Project layout

```text
src/cinderstore.cr       Library entry point
src/cinderstore/         Core components
src/cli.cr               Command line tool
examples/demo.cr         Library walkthrough
examples/server_demo.cr  Wire protocol walkthrough
fixtures/catalog.csv     Sample product catalog
spec/                    Test suite
```

## Test status

The suite runs with `crystal spec`. It has 87 examples. All pass on Windows
and Linux. It covers the skip list, the memory table, the write ahead log,
the bloom filter, and the block cache. It covers the tables, the iterators,
and the database. It covers compaction, leveled cascades, durability, and the
server protocol.

The CI workflow runs on GitHub Actions for Windows and Ubuntu. It checks
formatting, runs the suite, and builds the binary.

## Limitations

- Keys sort by byte value.
- Values are limited to 4 MB.
- Keys are limited to 4 KB.
- The server protocol is unencrypted. Use it on localhost only.
- Compaction merges one level at a time.
- The server uses fibers. It needs no multi-threaded runtime.

## Roadmap

- Release 0.2: leveled compaction — complete
- Release 0.3: snapshot iterators and consistent reads
- Release 0.4: optional checksum-free fast mode
- Release 0.5: batch writes and group commit
- Release 0.6: secondary indexes

## License

Cinderstore is licensed under the Apache License 2.0. See the `LICENSE` file.
