require "json"

module Cinderstore
  # An embeddable log structured merge tree.
  #
  # Writes go to a memtable and a write ahead log. When the memtable grows
  # past its limit we flush it to a sorted table. Background compaction
  # merges tables and drops stale data. Reads merge the memtable and all
  # tables, which makes every view consistent with the write order.
  class DB
    MANIFEST_NAME     = "MANIFEST"
    WAL_SUFFIX        = ".wal"
    SST_SUFFIX        = ".sst"
    TMP_SUFFIX        = ".sst.tmp"
    MAX_TABLE_ENTRIES = 20_000
    MAX_KEY_BYTES     =   4096
    MAX_VALUE_BYTES   = 4 * 1024 * 1024

    # Tuning options for a database instance.
    class Config
      # Target bytes for one table block.
      property block_size : Int32 = 4096
      # Approximate memtable size that triggers a flush.
      property memtable_limit : Int64 = 4_i64 * 1024 * 1024
      # Target false positive rate for per-table bloom filters.
      property bloom_fpp : Float64 = 0.01
      # Number of decoded blocks held in the cache.
      property cache_blocks : Int32 = 512
      # Fsync after every write when true.
      property sync_writes : Bool = true
      # Write CRC32 checksums on new data when true. Set to false for
      # higher throughput. Reads still verify files that carry checksums.
      property checksums : Bool = true
      # Number of level-0 tables that trigger compaction.
      property l0_compact_threshold : Int32 = 4
      # Start background compaction after a flush when true.
      property compact_on_flush : Bool = true
      # Upper bound on the number of levels, including level 0.
      property max_levels : Int32 = 7
      # Size ratio between levels. Level L may hold up to `level_ratio`
      # times the data of level L - 1. A higher ratio runs less often.
      property level_ratio : Float64 = 10.0
    end

    # A snapshot of database counters for reporting.
    class Stats
      getter tables : Int32
      getter l0 : Int32
      getter l1 : Int32
      getter level_counts : Array(Int32)
      getter entries : Int64
      getter disk_bytes : Int64
      getter memtable_bytes : Int64
      getter wal_bytes : Int64
      getter seq : Int64
      getter cache_hits : Int64
      getter cache_misses : Int64
      getter writes : Int64
      getter commits : Int64

      def initialize(@tables : Int32, @l0 : Int32, @l1 : Int32, @level_counts : Array(Int32),
                     @entries : Int64, @disk_bytes : Int64, @memtable_bytes : Int64,
                     @wal_bytes : Int64, @seq : Int64, @cache_hits : Int64, @cache_misses : Int64,
                     @writes : Int64, @commits : Int64)
      end

      def to_h : Hash(String, Int32 | Int64 | Array(Int32))
        {
          "tables"         => @tables,
          "l0"             => @l0,
          "l1"             => @l1,
          "levels"         => @level_counts,
          "entries"        => @entries,
          "disk_bytes"     => @disk_bytes,
          "memtable_bytes" => @memtable_bytes,
          "wal_bytes"      => @wal_bytes,
          "seq"            => @seq,
          "cache_hits"     => @cache_hits,
          "cache_misses"   => @cache_misses,
          "writes"         => @writes,
          "commits"        => @commits,
        }
      end

      def to_json(io : IO) : Nil
        to_h.to_json(io)
      end

      def to_s(io : IO) : Nil
        io << "tables: #{@tables} (l0: #{@l0}, l1: #{@l1})\n"
        io << "levels: #{@level_counts}\n"
        io << "entries: #{@entries}\n"
        io << "disk bytes: #{@disk_bytes}\n"
        io << "memtable bytes: #{@memtable_bytes}\n"
        io << "wal bytes: #{@wal_bytes}\n"
        io << "sequence: #{@seq}\n"
        io << "cache hits: #{@cache_hits}, misses: #{@cache_misses}\n"
        io << "writes: #{@writes}, commits: #{@commits}"
      end
    end

    # A live reference to one sorted table file.
    class TableRef
      getter id : Int64
      getter first : String
      getter last : String
      getter count : Int64
      getter index_count : Int64
      getter path : String

      @reader : SstableReader?
      @refs : Int32 = 1
      @orphaned : Bool = false

      def initialize(@id : Int64, @first : String, @last : String, @count : Int64, @path : String,
                     @index_count : Int64 = 0_i64)
      end

      # Returns the cached reader for this table.
      def reader(cache : BlockCache) : SstableReader
        r = @reader
        unless r
          r = SstableReader.new(@path, @id, cache)
          @reader = r
        end
        r
      end

      # Takes one extra reference. Snapshots use this to keep the table file
      # alive while they read it.
      def retain : Nil
        @refs += 1
      end

      # Drops one reference. The reader closes and the file is deleted when
      # the last reference leaves and the table no longer belongs to the
      # database.
      def release : Nil
        @refs -= 1
        if @refs <= 0
          close
          if @orphaned
            File.delete(@path) if File.exists?(@path)
          end
        end
      end

      # Marks the table as removed from the database. Its file is deleted
      # once every reference, including snapshot references, is released.
      def orphan : Nil
        @orphaned = true
      end

      def orphaned? : Bool
        @orphaned
      end

      def close : Nil
        @reader.try(&.close)
        @reader = nil
      end
    end

    @path : String
    @config : Config
    @lock = Mutex.new
    @flush_lock = Mutex.new
    @closed = false
    @mem : MemTable
    @frozen : MemTable? = nil
    @wal : Wal::Writer? = nil
    @old_wal : Wal::Writer? = nil
    @stale_wals : Array(String)? = nil
    @levels : Array(Array(TableRef))
    @seq : Int64 = 0_i64
    @next_id : Int64 = 1_i64
    @block_cache : BlockCache
    @flushing = false
    @compacting = false
    @pending_table_id : Int64 = 0_i64
    @manifest : Manifest? = nil
    @writes : Int64 = 0_i64
    @commit_group : CommitGroup? = nil
    @indexers : Hash(String, Proc(String, String, Array(String)))

    def initialize(path : String, config : Config = Config.new)
      @path = path
      @config = config
      @mem = MemTable.new
      @levels = [[] of TableRef]
      @block_cache = BlockCache.new(config.cache_blocks)
      @indexers = {} of String => Proc(String, String, Array(String))
      open
      @commit_group = CommitGroup.new if config.sync_writes
    end

    def path : String
      @path
    end

    # Registers a secondary index with a custom extractor.
    #
    # The block receives the primary key and its value. It returns the
    # index keys that identify the value. The store maintains the index
    # on every write. Call `query` to find the primary keys that share an
    # index key.
    def create_index(name : String, &indexer : String, String -> Array(String)) : Nil
      validate_index_name(name)
      @lock.synchronize do
        check_open
        raise InvalidIndexError.new("index already exists: #{name}") if @indexers.has_key?(name)
        @indexers[name] = indexer
      end
    end

    # Registers an index that reads one JSON field from every value.
    #
    # A scalar field yields one index key. An array field yields one key
    # per element. A value that is not JSON, or that lacks the field,
    # yields no index keys. The indexer never fails a write.
    def create_json_index(name : String, field : String) : Nil
      raise InvalidIndexError.new("field must not be empty") if field.empty?
      create_index(name) do |_key, value|
        doc = JSON.parse(value)
        Index.json_field_keys(doc, field)
      rescue JSON::ParseException
        [] of String
      end
    end

    # Returns true when `name` is a registered index.
    def index?(name : String) : Bool
      @lock.synchronize { @indexers.has_key?(name) }
    end

    # Returns the names of all registered indexes, in creation order.
    def indexes : Array(String)
      @lock.synchronize { @indexers.keys }
    end

    # Returns the primary keys whose value maps to `index_key` in `index`.
    #
    # The keys come back in primary key order. A negative `limit` means no
    # limit. The query reads the materialized index entries, so it works
    # whether or not the index is registered in this process.
    def query(index : String, index_key : String, limit : Int32 = -1) : Array(String)
      validate_index_name(index)
      @lock.synchronize do
        check_open
        prefix = Index.exact_prefix(index, index_key)
        keys = [] of String
        iter = make_merge_iter(prefix, false)
        while entry = iter.next?
          break unless entry.key.starts_with?(prefix)
          if entry.alive
            keys << Index.primary_key_of(entry.key)
            break if limit >= 0 && keys.size >= limit
          end
        end
        keys
      end
    end

    # Returns the primary keys whose index key lies in [start, finish).
    #
    # The keys come back in index key order, then primary key order. A nil
    # `finish_key` means no upper bound. A negative `limit` means no limit.
    def query_range(index : String, start_key : String = "", finish_key : String? = nil,
                    limit : Int32 = -1) : Array(String)
      validate_index_name(index)
      @lock.synchronize do
        check_open
        prefix = Index.name_prefix(index)
        start = "#{prefix}#{start_key}#{Index::SEP}"
        keys = [] of String
        iter = make_merge_iter(start, false)
        while entry = iter.next?
          break unless entry.key.starts_with?(prefix)
          index_key = Index.index_key_of(entry.key)
          break if finish_key && index_key >= finish_key
          if entry.alive
            keys << Index.primary_key_of(entry.key)
            break if limit >= 0 && keys.size >= limit
          end
        end
        keys
      end
    end

    # Returns a streaming iterator over the primary keys that map to
    # `index_key` in `index`.
    #
    # The iterator reads a snapshot taken at creation, so it stays
    # consistent while the store keeps writing. Keys come back in primary
    # key order. The iterator owns its snapshot, so call `close` when you
    # are done; that releases the snapshot.
    def query_iter(index : String, index_key : String) : IndexIter
      validate_index_name(index)
      snap = snapshot
      begin
        iter = snap.query_iter(index, index_key)
        iter.take_ownership
        iter
      rescue ex
        snap.release
        raise ex
      end
    end

    # Returns a streaming iterator over the primary keys whose index key
    # lies in [start, finish).
    #
    # The keys come back in index key order, then primary key order. A nil
    # `finish_key` means no upper bound. The iterator reads a snapshot
    # taken at creation, so it stays consistent while the store keeps
    # writing. The iterator owns its snapshot, so call `close` when you are
    # done; that releases the snapshot.
    def query_range_iter(index : String, start_key : String = "", finish_key : String? = nil) : IndexIter
      validate_index_name(index)
      snap = snapshot
      begin
        iter = snap.query_range_iter(index, start_key, finish_key)
        iter.take_ownership
        iter
      rescue ex
        snap.release
        raise ex
      end
    end

    # Writes a value for `key`.
    def put(key : String, value : String) : Nil
      validate_key(key)
      raise InvalidValueError.new("value exceeds #{MAX_VALUE_BYTES} bytes") if value.bytesize > MAX_VALUE_BYTES
      wal : Wal::Writer? = nil
      @lock.synchronize do
        check_open
        @seq += 1
        seq = @seq
        entries = maintenance_entries_for(seq, key, value)
        main = Entry.new(key, seq, true, value)
        wal = @wal.not_nil!
        if entries.empty?
          wal.append(main)
        else
          wal.append_batch([main] + entries)
        end
        @mem.put(key, value, seq)
        apply_index_entries(entries)
        @writes += 1
      end
      commit_wal(wal.not_nil!)
      trigger_flush
    end

    # Writes a tombstone for `key`.
    def delete(key : String) : Nil
      validate_key(key)
      wal : Wal::Writer? = nil
      @lock.synchronize do
        check_open
        @seq += 1
        seq = @seq
        entries = maintenance_entries_for(seq, key, nil)
        main = Entry.new(key, seq, false, "")
        wal = @wal.not_nil!
        if entries.empty?
          wal.append(main)
        else
          wal.append_batch([main] + entries)
        end
        @mem.delete(key, seq)
        apply_index_entries(entries)
        @writes += 1
      end
      commit_wal(wal.not_nil!)
    end

    # Applies `batch` atomically.
    #
    # Every queued operation becomes one record in the write ahead log. A
    # crash before the record is durable drops the whole batch, so the
    # store never applies part of it. The sequence numbers of a batch are
    # consecutive and assigned in queue order.
    def write(batch : Batch) : Nil
      return if batch.empty?
      wal : Wal::Writer? = nil
      @lock.synchronize do
        check_open
        ops = [] of Tuple(String, String, Bool)
        batch.each do |key, value, alive|
          validate_key(key)
          raise InvalidValueError.new("value exceeds #{MAX_VALUE_BYTES} bytes") if value.bytesize > MAX_VALUE_BYTES
          ops << {key, value, alive}
        end
        return if ops.empty?
        entries = [] of Entry
        # The index keys a batch op sees start from the previous value the
        # batch wrote for the key, or from the store when the batch is the
        # first to touch the key.
        current_keys = {} of String => Hash(String, Array(String))
        touched = {} of String => Bool
        ops.each do |key, value, alive|
          @seq += 1
          seq = @seq
          unless touched[key]?
            touched[key] = true
            current_keys[key] = index_keys_for(key, read_live_value(key))
          end
          new_keys = alive ? index_keys_for(key, value) : {} of String => Array(String)
          entries << Entry.new(key, seq, alive, value)
          entries.concat(index_delta_entries(seq, key, current_keys[key], new_keys))
          current_keys[key] = new_keys
        end
        wal = @wal.not_nil!
        wal.append_batch(entries)
        entries.each do |entry|
          if entry.alive
            @mem.put(entry.key, entry.value, entry.seq)
          else
            @mem.delete(entry.key, entry.seq)
          end
        end
        @writes += 1
      end
      commit_wal(wal.not_nil!)
      trigger_flush
    end

    # Builds a batch in a block, then writes it atomically.
    def write(&block : Batch ->) : Nil
      batch = Batch.new
      yield batch
      write(batch)
    end

    # Returns the live value for `key`, or nil.
    def get(key : String) : String?
      validate_key(key)
      @lock.synchronize do
        check_open
        if entry = @mem.get_entry(key)
          return entry.alive ? entry.value : nil
        end
        if entry = @frozen.try { |m| m.get_entry(key) }
          return entry.alive ? entry.value : nil
        end
        iter = LiveIter.new(make_merge_iter(key, true))
        if entry = iter.next?
          return entry.value if entry.key == key
        end
        nil
      end
    end

    # Yields live key/value pairs in key order. The range is [start, finish).
    def each(start_key : String = "", finish_key : String? = nil, &block : String, String ->) : Nil
      pairs = @lock.synchronize do
        check_open
        collect_range(start_key, finish_key, -1)
      end
      pairs.each { |key, value| yield key, value }
    end

    # Returns live key/value pairs whose keys start with `prefix`.
    # A negative limit means no limit.
    def scan_prefix(prefix : String, limit : Int32 = -1) : Array(Tuple(String, String))
      iter = scan_prefix_iter(prefix)
      result = [] of Tuple(String, String)
      begin
        while pair = iter.next?
          result << pair
          break if limit >= 0 && result.size >= limit
        end
        result
      ensure
        iter.close
      end
    end

    # Returns live key/value pairs in key order. The range is [start, finish).
    # A negative limit means no limit.
    def scan(start_key : String = "", finish_key : String? = nil, limit : Int32 = -1) : Array(Tuple(String, String))
      @lock.synchronize do
        check_open
        collect_range(start_key, finish_key, limit)
      end
    end

    # Returns a streaming iterator over live pairs whose keys start with
    # `prefix`. The iterator owns the snapshot it creates.
    def scan_prefix_iter(prefix : String) : ScanIter
      snap = snapshot
      begin
        iter = snap.scan_prefix_iter(prefix)
        iter.take_ownership
        iter
      rescue ex
        snap.release
        raise ex
      end
    end

    # Returns a streaming iterator over live key/value pairs in key order.
    #
    # The iterator reads a snapshot taken at creation, so it stays
    # consistent while the store keeps writing. The range is [start, finish).
    # The iterator owns its snapshot. Call `close` when you are done.
    #
    def scan_iter(start_key : String = "", finish_key : String? = nil) : ScanIter
      snap = snapshot
      begin
        iter = snap.scan_iter(start_key, finish_key)
        iter.take_ownership
        iter
      rescue ex
        snap.release
        raise ex
      end
    end

    # Flushes the active memtable to a new sorted table.
    def flush : Nil
      @flush_lock.synchronize do
        do_flush
      end
      trigger_compact
    end

    # Merges all tables into a fresh, non-overlapping level-1 set.
    def compact : Nil
      @flush_lock.synchronize do
        do_compact
      end
    end

    # Runs level-by-level compaction until every level is within its target.
    #
    # Level 0 merges into level 1 when it holds enough tables. Deeper levels
    # merge into the level below when they exceed their size target. Returns
    # true when any table moved. The automatic background task uses this.
    def compact_levels : Bool
      @flush_lock.synchronize do
        moved = false
        loop do
          level = @lock.synchronize do
            return false if @closed
            level_needing_compaction
          end
          break unless level
          moved = true
          compact_level_into(level)
        end
        moved
      end
    end

    # Returns an immutable view of the store at this instant.
    #
    # A snapshot copies the active memory table and keeps the table files it
    # references alive. Later writes, flushes, and compactions do not change
    # what the snapshot sees. Release the snapshot with `release` when you
    # are done with it.
    def snapshot : Snapshot
      @lock.synchronize do
        check_open
        tables = @levels.map { |level| level.dup }
        Snapshot.new(@seq, @mem.dup, @frozen, tables, @config.cache_blocks)
      end
    end

    # Returns an immutable view of the store, then releases it after the
    # block finishes.
    def snapshot(& : Snapshot ->) : Nil
      snap = snapshot
      begin
        yield snap
      ensure
        snap.release
      end
    end

    # Returns a snapshot of database counters.
    def stats : Stats
      @lock.synchronize do
        check_open
        table_refs = @levels.flatten
        disk_bytes = table_refs.sum { |ref| file_size(ref.path) }
        entries = table_refs.sum { |ref| ref.count - ref.index_count } +
                  (@mem.size - @mem.index_count) +
                  (@frozen.try { |m| m.size - m.index_count } || 0_i64)
        wal_bytes = 0_i64
        Dir.children(@path).each do |name|
          wal_bytes += file_size(File.join(@path, name)) if name.ends_with?(WAL_SUFFIX)
        end
        Stats.new(
          tables: table_refs.size,
          l0: @levels[0].size,
          l1: @levels.size > 1 ? @levels[1].size : 0,
          level_counts: @levels.map(&.size),
          entries: entries,
          disk_bytes: disk_bytes,
          memtable_bytes: @mem.approximate_bytes,
          wal_bytes: wal_bytes,
          seq: @seq,
          cache_hits: @block_cache.hits,
          cache_misses: @block_cache.misses,
          writes: @writes,
          commits: @commit_group.try(&.commits) || 0_i64,
        )
      end
    end

    # Flushes pending work, syncs the manifest, and releases file handles.
    def close : Nil
      @flush_lock.synchronize do
        @lock.synchronize do
          return if @closed
          @closed = true
          @wal.not_nil!.close
          @old_wal.try(&.close)
          save_manifest
          @levels.flatten.each(&.close)
        end
      end
      @commit_group.try(&.shutdown)
    end

    # ------------------------------------------------------------------
    # Secondary indexes
    # ------------------------------------------------------------------

    # Builds the index entries a single write needs.
    #
    # The previous live value of the key supplies the old index keys. The
    # new value supplies the new keys. Removed associations become index
    # tombstones. Added associations become live entries. A newer entry
    # supersedes an older one for the same association, so stale entries
    # drop naturally during compaction.
    private def maintenance_entries_for(seq : Int64, key : String, new_value : String?) : Array(Entry)
      return [] of Entry if @indexers.empty?
      new_keys = new_value ? index_keys_for(key, new_value) : {} of String => Array(String)
      old_keys = index_keys_for(key, read_live_value(key))
      index_delta_entries(seq, key, old_keys, new_keys)
    end

    # Returns the current live value for `key`, or nil. Callers hold the
    # database lock, so the value is consistent with the write order.
    private def read_live_value(key : String) : String?
      if entry = @mem.get_entry(key)
        return entry.alive ? entry.value : nil
      end
      if entry = @frozen.try { |m| m.get_entry(key) }
        return entry.alive ? entry.value : nil
      end
      iter = LiveIter.new(make_merge_iter(key, true))
      if entry = iter.next?
        return entry.value if entry.key == key
      end
      nil
    end

    # Returns the index keys every registered index derives from `value`.
    private def index_keys_for(key : String, value : String?) : Hash(String, Array(String))
      result = {} of String => Array(String)
      return result if value.nil?
      @indexers.each do |name, indexer|
        indexer.call(key, value).each do |index_key|
          raise InvalidIndexError.new("index key for #{name} contains a NUL byte") if index_key.includes?(Index::SEP)
          next if index_key.empty?
          (result[name] ||= [] of String) << index_key
        end
      end
      result.each { |name, keys| result[name] = keys.uniq }
      result
    end

    # Builds the entries that move an association from `old_keys` to
    # `new_keys`. Added index keys become live entries. Removed index
    # keys become tombstones. Each entry shares the sequence number of the
    # primary write, so both land in one write ahead log record.
    private def index_delta_entries(seq : Int64, key : String,
                                    old_keys : Hash(String, Array(String)),
                                    new_keys : Hash(String, Array(String))) : Array(Entry)
      return [] of Entry if @indexers.empty?
      raise InvalidKeyError.new("keys with a NUL byte cannot be indexed") if key.includes?(Index::SEP)
      entries = [] of Entry
      @indexers.each_key do |name|
        added = new_keys[name]? || [] of String
        removed = old_keys[name]? || [] of String
        (added - removed).each do |index_key|
          entries << Entry.new(Index.entry_key(name, index_key, key), seq, true, "")
        end
        (removed - added).each do |index_key|
          entries << Entry.new(Index.entry_key(name, index_key, key), seq, false, "")
        end
      end
      entries
    end

    # Applies index entries to the memtable after a write.
    private def apply_index_entries(entries : Array(Entry)) : Nil
      entries.each do |entry|
        if entry.alive
          @mem.put(entry.key, "", entry.seq)
        else
          @mem.delete(entry.key, entry.seq)
        end
      end
    end

    private def validate_index_name(name : String) : Nil
      raise InvalidIndexError.new("index name must not be empty") if name.empty?
      raise InvalidIndexError.new("index name contains a NUL byte") if name.includes?(Index::SEP)
    end

    # ------------------------------------------------------------------
    # Open and recovery
    # ------------------------------------------------------------------

    private def open : Nil
      Dir.mkdir_p(@path)
      manifest_path = File.join(@path, MANIFEST_NAME)
      manifest = File.exists?(manifest_path) ? Manifest.load(manifest_path) : Manifest.new
      @manifest = manifest
      @seq = manifest.seq
      @next_id = manifest.next_id
      load_tables(manifest)
      clean_orphans
      recover_wals
      create_active_wal
    end

    private def load_tables(manifest : Manifest) : Nil
      @levels = manifest.levels.map do |level|
        level.map do |info|
          TableRef.new(info.id, info.first, info.last, info.count, table_path(info.id), info.index_count)
        end
      end
      @levels = [[] of TableRef] if @levels.empty?
    end

    private def clean_orphans : Nil
      known = @levels.flatten.map(&.id)
      Dir.children(@path).each do |name|
        if name.ends_with?(SST_SUFFIX)
          id = name.rpartition(".")[0].to_i64
          unless known.includes?(id)
            File.delete(File.join(@path, name)) rescue nil
          end
        elsif name.ends_with?(".tmp")
          File.delete(File.join(@path, name)) rescue nil
        end
      end
    end

    private def recover_wals : Nil
      files = Dir.children(@path).select { |name| name.ends_with?(WAL_SUFFIX) }.sort
      files.each do |name|
        full = File.join(@path, name)
        @seq = Wal.recover(full, @mem, @seq)
      end
      # The memtable now holds what the logs held. Keep the logs so that a
      # crash before the next flush does not lose data. Empty logs carry no
      # data, so we can drop them.
      if @mem.empty?
        files.each do |name|
          File.delete(File.join(@path, name)) rescue nil
        end
      end
    end

    private def create_active_wal : Nil
      id = @next_id
      @next_id += 1
      @wal = Wal::Writer.new(wal_path(id), @config.sync_writes, @config.checksums)
    end

    # ------------------------------------------------------------------
    # Read path
    # ------------------------------------------------------------------

    private def collect_range(start_key : String, finish_key : String?, limit : Int32) : Array(Tuple(String, String))
      result = [] of Tuple(String, String)
      iter = LiveIter.new(make_merge_iter(start_key, false))
      while entry = iter.next?
        if finish_key && entry.key >= finish_key
          break
        end
        result << {entry.key, entry.value}
        break if limit >= 0 && result.size >= limit
      end
      result
    end

    private def make_merge_iter(start : String, bloom_guard : Bool) : MergeIter
      sources = [] of Store::Iter
      if frozen = @frozen
        sources << MemIter.new(frozen, start)
      end
      sources << MemIter.new(@mem, start)
      @levels.flatten.each do |ref|
        reader = ref.reader(@block_cache)
        if bloom_guard && !reader.bloom_may_contain?(start)
          next
        end
        sources << TableIter.new(reader, start)
      end
      MergeIter.new(sources)
    end

    # ------------------------------------------------------------------
    # Flush
    # ------------------------------------------------------------------

    private def do_flush : Nil
      if @frozen.nil?
        @lock.synchronize do
          return if @closed
          return if @mem.empty?
          @frozen = @mem
          @mem = MemTable.new
          @old_wal = @wal
          # Every log present now is fully represented by the frozen
          # memtable, so each one can be dropped once the table is durable.
          @stale_wals = Dir.children(@path).select { |name| name.ends_with?(WAL_SUFFIX) }
          @pending_table_id = @next_id
          @next_id += 1
          wal_id = @next_id
          @next_id += 1
          @wal = Wal::Writer.new(wal_path(wal_id), @config.sync_writes, @config.checksums)
        end
      end

      table_id = @pending_table_id
      frozen = @frozen.not_nil!
      meta = write_memtable_to_table(table_id, frozen)

      @lock.synchronize do
        @levels[0] << TableRef.new(meta.id, meta.first, meta.last, meta.count, table_path(meta.id), meta.index_count)
        @frozen = nil
        if old = @old_wal
          old.close
          @old_wal = nil
        end
        if stale = @stale_wals
          stale.each do |name|
            File.delete(File.join(@path, name)) rescue nil
          end
          @stale_wals = nil
        end
        save_manifest
      end
    end

    private def write_memtable_to_table(table_id : Int64, mem : MemTable) : TableMeta
      tmp_path = File.join(@path, "#{Util.file_stem(table_id)}#{TMP_SUFFIX}")
      final_path = table_path(table_id)
      meta = nil
      File.open(tmp_path, "w") do |io|
        writer = SstableWriter.new(io, table_id, @config.block_size, @config.bloom_fpp, @config.checksums)
        mem.each_entry do |entry|
          writer.add(entry.key, entry.value, entry.seq, entry.alive)
        end
        meta = writer.finish
        io.flush
      end
      File.rename(tmp_path, final_path)
      meta.not_nil!
    end

    private def trigger_flush : Nil
      return if @mem.approximate_bytes < @config.memtable_limit
      return if @flushing
      @flushing = true
      spawn do
        begin
          flush
        ensure
          @flushing = false
        end
      end
    end

    # Makes the appended record durable.
    #
    # With `sync_writes` enabled the commit group batches this call with
    # concurrent writers, so one fsync covers many records. Without it, no
    # fsync happens and the call returns immediately.
    private def commit_wal(wal : Wal::Writer) : Nil
      if group = @commit_group
        group.commit(wal)
      end
    end

    private def trigger_compact : Nil
      return unless @config.compact_on_flush
      return if @compacting
      needs = @lock.synchronize { !level_needing_compaction.nil? }
      return unless needs
      @compacting = true
      spawn do
        begin
          compact_levels
        ensure
          @compacting = false
        end
      end
    end

    # ------------------------------------------------------------------
    # Compaction
    # ------------------------------------------------------------------

    # Merges every table into a fresh, non-overlapping level-1 set.
    private def do_compact : Nil
      tables = nil
      @lock.synchronize do
        return if @closed
        tables = @levels.flatten
        return if tables.size < 2
      end

      outputs = merge_tables(tables.not_nil!, true)

      @lock.synchronize do
        @levels = [[] of TableRef, outputs.map { |m| TableRef.new(m.id, m.first, m.last, m.count, table_path(m.id), m.index_count) }]
        save_manifest
        tables.not_nil!.each do |ref|
          # Mark the table as gone, then drop the database reference. The
          # file stays on disk until every snapshot reference is released.
          ref.orphan
          ref.release
        end
      end
    end

    # Returns the lowest level that needs compaction, or nil.
    #
    # Level 0 compacts by table count. Deeper levels compact when they hold
    # more bytes than their target. The deepest level never compacts.
    private def level_needing_compaction : Int32?
      return nil if @config.max_levels < 2
      return 0 if @levels[0].size >= @config.l0_compact_threshold
      max_source = Math.min(@levels.size, @config.max_levels - 1) - 1
      return nil if max_source < 1
      (1..max_source).each do |level|
        next if @levels[level].empty?
        return level if level_size(level) > level_target(level)
      end
      nil
    end

    # Merges one level into the level below it.
    #
    # The merged range keeps the newest entry per key. Tombstones are kept
    # unless the target level is the deepest, because deeper tables may hold
    # older copies that the tombstone must hide.
    private def compact_level_into(level : Int32) : Nil
      target = level + 1
      @lock.synchronize do
        return if @closed
        while @levels.size <= target
          @levels << [] of TableRef
        end
      end

      source_tables = nil
      overlap = nil
      @lock.synchronize do
        source = @levels[level]
        return if source.empty?
        source_tables = source.dup
        first = source.map(&.first).min
        last = source.map(&.last).max
        # Tables in the target level that overlap the source range. The
        # target level is non-overlapping, so these form one contiguous set.
        overlap = @levels[target].select { |ref| ref.last >= first && ref.first <= last }
      end

      inputs = source_tables.not_nil! + overlap.not_nil!
      outputs = merge_tables(inputs, no_data_below?(target))

      @lock.synchronize do
        return if @closed
        kept = @levels[target].select { |ref| !overlap.not_nil!.includes?(ref) }
        @levels[target] = (kept + outputs.map { |m| TableRef.new(m.id, m.first, m.last, m.count, table_path(m.id), m.index_count) }).sort_by!(&.first)
        @levels[level] = [] of TableRef
        inputs.each do |ref|
          ref.orphan
          ref.release
        end
        save_manifest
      end
    end

    # Merges tables into fresh tables. Keeps the newest entry per key.
    # Drops tombstones only when `drop_tombstones` is true.
    private def merge_tables(tables : Array(TableRef), drop_tombstones : Bool) : Array(TableMeta)
      readers = @lock.synchronize { tables.map { |ref| ref.reader(@block_cache) } }
      sources = [] of Store::Iter
      readers.each { |reader| sources << TableIter.new(reader) }
      iter = MergeIter.new(sources)
      outputs = [] of TableMeta
      writer : SstableWriter? = nil
      io : File? = nil
      current_id : Int64 = 0
      written = 0

      finish_output = -> {
        if w = writer
          meta = w.finish
          io.not_nil!.flush
          io.not_nil!.close
          io = nil
          writer = nil
          File.rename(File.join(@path, "#{Util.file_stem(current_id)}#{TMP_SUFFIX}"), table_path(current_id))
          outputs << meta
          written = 0
        end
      }

      while entry = iter.next?
        next if drop_tombstones && !entry.alive
        if writer.nil?
          current_id = @lock.synchronize do
            id = @next_id
            @next_id += 1
            id
          end
          io = File.open(File.join(@path, "#{Util.file_stem(current_id)}#{TMP_SUFFIX}"), "w")
          writer = SstableWriter.new(io.not_nil!, current_id, @config.block_size, @config.bloom_fpp, @config.checksums)
        end
        writer.not_nil!.add(entry.key, entry.value, entry.seq, entry.alive)
        written += 1
        finish_output.call if written >= MAX_TABLE_ENTRIES
      end
      finish_output.call
      outputs
    end

    # Returns true when every level below `level` holds no tables.
    private def no_data_below?(level : Int32) : Bool
      ((level + 1)...@levels.size).all? { |l| @levels[l].empty? }
    end

    # Returns the total bytes held by one level.
    private def level_size(level : Int32) : Int64
      @levels[level].sum { |ref| file_size(ref.path) }
    end

    # Returns the size target for a level. Each level may hold up to
    # `level_ratio` times the data of the level above it.
    private def level_target(level : Int32) : Int64
      scale = @config.level_ratio ** level
      (@config.memtable_limit * scale).to_i64
    end

    # ------------------------------------------------------------------
    # Manifest and paths
    # ------------------------------------------------------------------

    private def save_manifest : Nil
      manifest = @manifest.not_nil!
      manifest.seq = @seq
      manifest.next_id = @next_id
      manifest.levels = @levels.map do |level|
        level.map do |ref|
          Manifest::TableInfo.new(ref.id, ref.first, ref.last, ref.count, ref.index_count)
        end
      end
      manifest.save(File.join(@path, MANIFEST_NAME))
    end

    private def wal_path(id : Int64) : String
      File.join(@path, "#{Util.file_stem(id)}#{WAL_SUFFIX}")
    end

    private def table_path(id : Int64) : String
      File.join(@path, "#{Util.file_stem(id)}#{SST_SUFFIX}")
    end

    private def validate_key(key : String) : Nil
      raise InvalidKeyError.new("key must not be empty") if key.empty?
      raise InvalidKeyError.new("key exceeds #{MAX_KEY_BYTES} bytes") if key.bytesize > MAX_KEY_BYTES
      raise InvalidKeyError.new("key starts with the reserved index prefix") if Index.internal_key?(key)
    end

    private def check_open : Nil
      raise ClosedError.new("database is closed") if @closed
    end

    private def file_size(path : String) : Int64
      File.size(path)
    rescue File::NotFoundError
      0_i64
    end
  end
end
