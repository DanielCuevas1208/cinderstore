# Cinderstore

[![CI](https://github.com/DanielCuevas1208/cinderstore/actions/workflows/ci.yml/badge.svg)](https://github.com/DanielCuevas1208/cinderstore/actions/workflows/ci.yml)

Cinderstore is an embeddable key and value store. It is built on a log
structured merge tree. It is written in Crystal and uses only the Crystal
standard library.

The store keeps a write ahead log for durability. It flushes memory to sorted
files. It merges those files during compaction. It recovers all data after a
restart. It serves `get`, `put`, `delete`, and `query` over a local socket.

Snapshots give you a consistent view of the store at one instant. A snapshot
never blocks new writes. Release it when you are done.

Secondary indexes map derived keys to primary keys. The store keeps each
index in sync with every write. Query an index to find the primary keys
behind one value.

This is release 0.7.0. It adds secondary indexes. An index writes into a
reserved part of the log structured merge tree. The write ahead log keeps
the index atomic with the data. Compaction drops stale index entries.

## Features

- Memory table with ordered writes
- Durable write ahead log with CRC32 framing
- Atomic batch writes in one log record
- Group commit that shares one fsync between writers
- Optional checksums for higher write throughput
- Sorted tables with a block index and a bloom filter
- Block cache for fast repeated reads
- Level-based compaction with size targets per level
- Background flush and compaction
- Point-in-time snapshots with consistent reads
- Snapshot iterators that stay valid during writes
- Range scans with an iterator API
- Secondary indexes with automatic maintenance
- JSON field indexes with one API call
- Exact and range queries over an index
- Crash recovery from the write ahead log
- Local TCP server with a line protocol
- Zero runtime dependencies

## Quick start

You need Crystal 1.21 or newer.

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

Run the demo in fast mode.

```console
bin/cinderstore demo --no-checksums
```

## Demo output

The demo loads a product catalog from `fixtures/catalog.csv`. It writes,
scans, flushes, compacts, deletes, snapshots, and reopens a database. It
creates secondary indexes and queries them. The output is deterministic.

```text
== Cinderstore 0.7.0 demo ==

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
   disk bytes: 1653, memtable bytes: 0

4. Delete 4 products, update 2 products, then flush again
   tables: 2 (l0: 2, l1: 0), entries: 30
   disk bytes: 1910, memtable bytes: 0
   The deleted keys still occupy space in the level-0 tables.

5. Compact merges the tables and drops the deleted keys
   tables: 1 (l0: 0, l1: 1), entries: 20
   disk bytes: 1388, memtable bytes: 0
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

8. Reopen the database and verify recovery
   rows after restart: 21

9. Leveled compaction keeps each level within its target
   after 5 flushes, level counts: [5]
   after compact_levels:          [0, 0, 1]
   all 100 rows still readable

10. Fast mode skips checksums on new writes
   checksummed: wal 5231 bytes, disk 5692 bytes
   fast mode:   wal 4943 bytes, disk 5548 bytes
   all 72 rows readable after a fast-mode restart

11. Batch writes and group commit
   one batch wrote 24 rows as 1 write operation
   sequence after the batch: 24
   all 24 rows recovered after a restart

   concurrent writes: 200, durability commits: 25
   all 200 rows recovered after a restart

12. Secondary indexes track derived views
   created indexes on name, price, and stock
   query by-name "Ash Rake Forged"  => SKU-0010
   query by-price "14.0"            => SKU-0010
   query by-stock "31"              => SKU-0010
   stock range 20 to 30               => SKU-0004, SKU-0023, SKU-0011, SKU-0003, SKU-0022, SKU-0006
   update SKU-0010 price to 15.50, then flush and compact
   query by-price "14.0"            => (none)
   query by-price "15.5"            => SKU-0010
   delete SKU-0011, then flush and compact
   query by-name "Coal Shovel Small" => (none)
   reopen and query by-stock "31"    => SKU-0010

Demo complete.
```

Step 7 shows the value of a snapshot. The live store drops SKU-0001 and adds
two products. The snapshot still sees the state before those writes.

Step 9 shows the value of leveled compaction. Five flushes create five
level-0 tables. `compact_levels` merges them into a fresh level-2 table, so
the store stays tidy as it grows.

Step 10 shows the value of fast mode. It writes the same 72 rows twice. Fast
mode skips the CRC32 on every log record and every table block. Its log is
288 bytes smaller, and its table is 144 bytes smaller. The data still round
trips after a restart.

Step 11 shows the value of batches and group commit. One batch writes 24 rows
in a single log record. Eight writers share one durability sync per round.
They write 200 rows with 25 syncs instead of 200. The store still recovers
every row after a restart.

Step 12 shows the value of secondary indexes. Three JSON indexes cover the
catalog. A price update moves SKU-0010 between index keys. A delete removes
SKU-0011 from its indexes. The store recovers every index after a restart.

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

### Write a batch

A batch applies many changes at once. All changes succeed together, or none
do. A batch is one write ahead log record. A crash cannot apply half of it.

```crystal
batch = Cinderstore::Batch.new
batch.put("bellows-copper", "in stock")
batch.put("chimney-brush", "sold out")
batch.delete("ash-rake")
db.write(batch)
```

Build a batch in a block.

```crystal
db.write do |b|
  b.put("bellows-copper", "in stock")
  b.delete("ash-rake")
end
```

A later operation in the batch overrides an earlier one. The operations use
consecutive sequence numbers in queue order.

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

### Use a secondary index

Create an index with an extractor. The block gets the primary key and its
value. It returns the index keys for that value.

```crystal
db.create_index("by-builder") do |key, value|
  [extract_builder(value)]
end
```

For JSON values, index one field with a name and a field name. A scalar
field yields one index key. An array field yields one key per element.

```crystal
db.create_json_index("by-price", "price")
db.create_json_index("by-name", "name")
```

Every put and delete updates each index. A value change moves its primary
key between index keys. A delete removes the key from every index.

Find the primary keys behind one index key.

```crystal
db.query("by-price", "14.0") # => ["SKU-0010"]
```

Find the primary keys behind a range of index keys. The range is
`[start, finish)`.

```crystal
db.query_range("by-price", "10", "20") # => ["SKU-0022", "SKU-0010"]
```

Query a snapshot for a consistent result.

```crystal
db.snapshot do |snap|
  snap.query("by-name", "Ash Rake Forged")
end
```

A query reads the stored index entries. It works without a registered
index in the current process. Index keys sort by byte value, like primary
keys.

Flush and compact explicitly.

```crystal
db.flush    # Move the memtable into a table.
db.compact  # Merge all tables into level 1.
```

`compact` merges every table in one pass. It drops stale data. For a growing
store, run `compact_levels` instead. It merges one level at a time, so each
pass touches only two levels. It returns true when any table moved.

```crystal
moved = db.compact_levels
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

Query a secondary index.

```console
bin/cinderstore query --index by-price --key 14.0
```

Query an index range.

```console
bin/cinderstore query --index by-stock --start 20 --finish 30
```

Show counters.

```console
bin/cinderstore stats
```

Start the local server.

```console
bin/cinderstore server --db data --port 7654
```

Start the server with JSON field indexes.

```console
bin/cinderstore server --db data --port 7654 --index by-price:price
```

Run the server in fast mode.

```console
bin/cinderstore server --db data --port 7654 --no-checksums
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
| `QUERY index index_key` | Query one index key |
| `QUERYRANGE index start finish` | Query an index range |
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
- `ROW key` for each index query result, then `END`
- `STATS {...}` for the counters
- `ERR message` for an error

A `QUERY` command returns the primary keys behind one index key. A
`QUERYRANGE` command returns the primary keys behind a range of index keys.
Both commands end with `END`.

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

The default mode syncs each commit group. Concurrent writers share one
group, so one fsync makes several writes durable. Set `sync_writes` to
`false` for faster, less durable writes. Set `checksums` to `false` to skip
the CRC32 on new data.

A batch follows the same path. Its entries become one log record. Group
commit still applies, so a batch waits for the same shared fsync.

A secondary index rides the same path. A write that changes an index appends
one batch record. The record holds the primary entry and its index entries.
The log keeps them atomic. A crash drops the whole record or nothing.

### Flush

When the memory table grows past its limit, the database freezes it. A new
memory table starts. A background task writes the frozen table to a sorted
file. The old log is deleted only after the file is durable.

### Compaction

Tables live in levels. Level 0 holds new flushes. Its tables may overlap.
Deeper levels hold merged tables. Tables in one level never overlap each
other.

Each level has a size target. The target grows by `level_ratio` for every
deeper level. Level 0 has no size target. It compacts by table count instead.

Compaction works one level at a time. Level 0 compacts when it holds enough
tables. A deeper level compacts when it holds more bytes than its target.
The merge reads that level and the overlapping tables in the next level. It
writes fresh tables into the next level.

A tombstone stays in the merged output until the deepest level. It must stay,
because a deeper table may hold an older copy that the tombstone hides. At
the deepest level, all older copies are gone, so the tombstone can drop.

The `compact` call merges every level in one pass. The `compact_levels` call
merges one level at a time. The background task uses `compact_levels`.

Compaction keeps a table file on disk while a snapshot references it. The
file is deleted only after the last snapshot releases it.

### Snapshots

A snapshot is an immutable view of the store at one instant. Creation copies
the active memory table and takes a reference to each table file.

Writes, flushes, and compactions after the snapshot do not change what the
snapshot sees. The snapshot reads the table files it holds, so compaction
can replace those files without breaking the snapshot.

Snapshots never block writes. Reads over a snapshot use the same merge path
as normal reads. Release a snapshot when you are done with it.

### Secondary indexes

An index entry is an ordinary entry in a reserved key namespace. The entry
key holds the index name, the index key, and the primary key. The namespace
uses the NUL byte, so it sorts before every user key.

The store maintains each index during a write. It reads the previous value
of the primary key. It runs the extractor on the old and the new value. A
new index key becomes a live entry. A removed index key becomes a tombstone.

The write ahead log keeps the primary entry and the index entries in one
batch record. Recovery restores both together. A newer tombstone supersedes
a stale entry, exactly as it does for primary keys. Compaction drops the
stale entries.

A query scans the index range in the merge path. It returns primary keys in
index key order, then primary key order. User reads never see the index
namespace. Scans, snapshots, and counters skip it.

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
- A footer stores offsets, a version, a flag, and a CRC32.
- Each block carries a CRC32 unless the flag turns it off.

The write ahead log starts with a header. The header holds a magic value and
a flag byte. The flag says whether records carry checksums and a kind byte.
The kind byte marks a single entry or a batch. The reader detects both
settings from the file itself.

Files from earlier releases have no header, or no kind byte. Their records
always carry checksums. The reader handles every layout, so an upgrade does
not lose data.

Sequence numbers make versions unique. They are per-write and never reused.

Index entries use a reserved key namespace inside the tables. The manifest
records how many index entries each table holds. Counters use this number
to hide the internal entries.

## Configuration

Tune the database with `Cinderstore::DB::Config`.

```crystal
config = Cinderstore::DB::Config.new
config.block_size = 4096
config.memtable_limit = 4_i64 * 1024 * 1024
config.bloom_fpp = 0.01
config.cache_blocks = 512
config.sync_writes = true
config.checksums = true
config.l0_compact_threshold = 4
config.compact_on_flush = true
config.max_levels = 7
config.level_ratio = 10.0
db = Cinderstore::DB.new("data", config)
```

`max_levels` caps the number of levels. `level_ratio` sets how much data a
deeper level may hold. A higher ratio compacts less often. Level L holds up
to `memtable_limit * level_ratio ** L` bytes.

`checksums` controls new writes. Set it to `false` to skip CRC32 checksums.
This raises write throughput and shrinks each log record by four bytes. Each
table block also saves four bytes. The reader still verifies files that
carry checksums. Use fast mode for ephemeral data or data you can rebuild.

`sync_writes` controls durability. When it is `true`, writers share commit
groups and wait for one shared fsync. A single sequential writer still syncs
once per write. When it is `false`, writes never fsync and return at once.

## Project layout

```text
src/cinderstore.cr       Library entry point
src/cinderstore/         Core components
src/cinderstore/batch.cr Atomic batch writes
src/cinderstore/commit_group.cr  Shared durability syncs
src/cinderstore/index.cr Secondary index namespace
src/cinderstore/snapshot.cr  Point-in-time snapshot support
src/cli.cr               Command line tool
examples/demo.cr         Library walkthrough
examples/server_demo.cr  Wire protocol walkthrough
fixtures/catalog.csv     Sample product catalog
spec/                    Test suite
```

## Test status

The suite runs with `crystal spec`. It has 172 examples. All pass on Windows
and Linux. It covers the skip list, the memory table, the write ahead log,
the bloom filter, and the block cache. It covers the tables, the iterators,
and the database. It covers batch writes, group commit, compaction by level,
durability, snapshots, and the server protocol. It covers both checksum
modes and the legacy file layouts. It covers secondary index maintenance,
queries, recovery, and snapshots.

The CI workflow runs on GitHub Actions for Windows and Ubuntu. It checks
formatting, runs the suite, runs both demos, and builds the binary.

## Limitations

- Keys sort by byte value. Index keys sort the same way.
- Values are limited to 4 MB.
- Keys are limited to 4 KB.
- Keys that start with the reserved index prefix are rejected.
- Keys with a NUL byte cannot be indexed.
- An index only covers writes made after it is created.
- The server protocol is unencrypted. Use it on localhost only.
- Fast mode cannot detect silent bit rot. It detects torn writes only.
- Group commit needs concurrent writers to share a sync. A single writer
  still syncs once per write.
- Index maintenance reads the previous value of each written key.
- Indexers must be deterministic. The same value must give the same keys.
- `compact_levels` merges a whole level at once. A very large level makes a
  large merge. The level targets keep that merge rare.
- No multi-threaded runtime is required. The server uses fibers.
- Release snapshots before you close the database.

## Roadmap

Planned:

- Release 0.8: streaming iterators for secondary index queries

Delivered:

- Release 0.7: secondary indexes. Index entries share the log structured
  merge tree. The store maintains each index on every write. Queries return
  the primary keys behind an index key.
- Release 0.6: batch writes and group commit. A batch is one atomic write
  ahead log record. Concurrent writers share one durability sync per group.
- Release 0.5: optional checksum-free fast mode. New data can skip CRC32
  checksums. The on-disk format records the mode, so old and new files mix
  safely.
- Release 0.4: level-based compaction. Tables cascade from level 0 to deeper
  levels. Each level stays within its size target. Tombstones survive until
  the deepest level.
- Release 0.3: snapshot iterators and consistent reads. Snapshots give a
  stable view of the store. Compaction keeps referenced files alive.

## License

Cinderstore is licensed under the Apache License 2.0. See the `LICENSE` file.
