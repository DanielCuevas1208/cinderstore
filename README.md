# Cinderstore

[![CI](https://github.com/DanielCuevas1208/cinderstore/actions/workflows/ci.yml/badge.svg)](https://github.com/DanielCuevas1208/cinderstore/actions/workflows/ci.yml)

Cinderstore is an embeddable key and value store. It is built on a log
structured merge tree (LSM tree). It is written in Crystal. It uses only
the Crystal standard library.

The store appends every write to a write ahead log. It flushes memory to
sorted files. It merges those files during compaction. It recovers all
data after a restart. It serves `get`, `put`, and `delete` over a local
socket.

Snapshots give a consistent view of the store at one instant. They never
block new writes. Release a snapshot when you are done with it.

This is release 0.4.0. It adds an optional checksum-free fast mode. The
mode skips CRC32 work for faster reads and writes.

## Features

- Memory table with ordered writes
- Write ahead log with CRC32 framing
- Sorted tables with a block index and a bloom filter
- Block cache for fast repeated reads
- Background flush and compaction
- Point-in-time snapshots with consistent reads
- Snapshot iterators that stay valid during writes
- Range scans with an iterator API
- Crash recovery from the write ahead log
- Local TCP server with a line protocol
- Optional checksum-free fast mode
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
scans, flushes, compacts, deletes, snapshots, and reopens a database. It
also shows the checksum-free mode. The output is deterministic.

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

8. Reopen the database and verify recovery
   rows after restart: 21

9. Checksum-free fast mode
   write, flush, and compact with checksums disabled
   fast rows: 5, checksums: false
   reopen with checksums enabled, rows: 5

Demo complete.
```

Step 7 shows the value of a snapshot. The live store drops SKU-0001 and
adds two products. The snapshot still sees the state before those writes.

Step 9 creates a second store with checksums disabled. The store survives
flush, compaction, and a mode switch.

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

Iterate a snapshot with a snapshot iterator. The iterator stays valid
while the database keeps writing. Close the iterator before you release
the snapshot.

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
db.compact  # Merge tables and drop deleted keys.
```

## Checksum-free fast mode

Every data block and log record carries a CRC32. The store verifies each
checksum when it reads data. Verification guards against silent
corruption. It also costs CPU time.

You can disable checksums. Set `checksums` to `false` in the
configuration. The store then skips checksum work. Reads and writes run
faster. The store accepts corruption without notice.

```crystal
config = Cinderstore::DB::Config.new
config.checksums = false
db = Cinderstore::DB.new("data", config)
```

The mode does not change correct behavior. Values survive a clean
restart. A torn log tail still stops recovery at the last intact record.

Use this mode only on reliable disks. Keep checksums on for critical
data.

The store records the mode in the manifest. Tables carry their own format
version. You can switch the mode on an existing database. The store
migrates the log on the next open. It never misreads old data.

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

Pass `--no-checksums` to any command to skip CRC32 checks.

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

The default mode fsyncs after every write. Set `sync_writes` to `false`
for faster, less durable writes.

### Flush

When the memory table grows past its limit, the database freezes it. A
new memory table starts. A background task writes the frozen table to a
sorted file. The old log is deleted only after the file is durable.

### Compaction

Level-0 tables may overlap. Compaction merges every table into a fresh,
non-overlapping level-1 set. The merge keeps the newest entry for each
key. It drops tombstones, because it includes all data. New writes
continue into the memory table during the merge.

Compaction keeps a table file on disk while a snapshot references it. The
file is deleted only after the last snapshot releases it.

### Snapshots

A snapshot is an immutable view of the store at one instant. Creation
copies the active memory table and takes a reference to each table file.

Writes, flushes, and compactions after the snapshot do not change what
the snapshot sees. The snapshot reads the table files it holds.
Compaction can replace those files without breaking the snapshot.

Snapshots never block writes. Reads over a snapshot use the same merge
path as normal reads. Release a snapshot when you are done with it.

### Read path

A read merges the memory table, any frozen table, and all sorted tables.
The merge yields the newest entry for each key. The bloom filter lets a
reader skip a table that cannot contain the key. The block cache holds
decoded blocks so repeated reads avoid disk.

### Checksum handling

Each data block and log record carries a CRC32. The reader verifies the
checksum when checksums are enabled. Tables carry a format version. The
version tells the reader whether to verify. The manifest records the log
mode. Recovery uses the recorded mode, so it never misreads a log.

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

Sequence numbers make versions unique. They are per-write and never
reused.

Checksum-free tables use format version 2. Version 1 tables always carry
checksums. The reader trusts the format version, not the configuration.

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
db = Cinderstore::DB.new("data", config)
```

## Project layout

```text
src/cinderstore.cr       Library entry point
src/cinderstore/         Core components
src/cinderstore/snapshot.cr  Point-in-time snapshot support
src/cli.cr               Command line tool
examples/demo.cr         Library walkthrough
examples/server_demo.cr  Wire protocol walkthrough
fixtures/catalog.csv     Sample product catalog
spec/                    Test suite
```

## Test status

The suite runs with `crystal spec`. It has 106 examples. All pass on
Windows and Linux. It covers the skip list, the memory table, the write
ahead log, the bloom filter, and the block cache. It covers the tables,
the iterators, and the database. It covers compaction, durability,
snapshots, checksum-free mode, and the server protocol.

The CI workflow runs on GitHub Actions for Windows and Ubuntu. It checks
formatting, runs the suite, runs the demo, and builds the binary.

## Limitations

- Keys sort by byte value.
- Values are limited to 4 MB.
- Keys are limited to 4 KB.
- The server protocol is unencrypted. Use it on localhost only.
- Compaction is a full merge. It is correct and simple, not incremental.
- No multi-threaded runtime is required. The server uses fibers.
- Release snapshots before you close the database.
- Checksum-free mode does not detect silent corruption. Use it only on
  reliable disks.

## Roadmap

See `ROADMAP.md` for the current plan.

## License

Cinderstore is licensed under the Apache License 2.0. See the `LICENSE`
file.
