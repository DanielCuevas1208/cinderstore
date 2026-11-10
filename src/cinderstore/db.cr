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
    EXPORT_BATCH_SIZE = 256

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
      # Maximum number of merged keys processed by one resumable full
      # compaction slice. Zero disables the budget.
      property compaction_work_budget : Int32 = 0
      # Maximum number of primary rows processed by one index build slice.
      property index_build_batch_size : Int32 = 256
    end

    # Inspectable state for one JSON index build.
    class IndexBuildStatus
      getter name : String
      getter state : String
      getter processed : Int64
      getter last_key : String

      def initialize(@name : String, @state : String, @processed : Int64, @last_key : String)
      end

      def ready? : Bool
        @state == "ready"
      end

      def to_h : Hash(String, String | Int64 | Bool)
        {
          "name"      => @name,
          "state"     => @state,
          "processed" => @processed,
          "last_key"  => @last_key,
          "ready"     => ready?,
        }
      end

      def to_json(io : IO) : Nil
        to_h.to_json(io)
      end

      def to_s(io : IO) : Nil
        io << "index #{@name}: #{@state}, processed #{@processed}, last key #{@last_key.inspect}"
      end
    end

    # A snapshot of database counters for reporting.
    class Stats
      getter tables : Int32
      getter l0 : Int32
      getter l1 : Int32
      getter level_counts : Array(Int32)
      getter level_bytes : Array(Int64)
      getter entries : Int64
      getter disk_bytes : Int64
      getter memtable_bytes : Int64
      getter wal_bytes : Int64
      getter seq : Int64
      getter cache_hits : Int64
      getter cache_misses : Int64
      getter writes : Int64
      getter commits : Int64
      getter logical_write_bytes : Int64
      getter flush_bytes_written : Int64
      getter compaction_input_tables : Int64
      getter compaction_input_entries : Int64
      getter compaction_input_bytes : Int64
      getter compaction_output_tables : Int64
      getter compaction_output_entries : Int64
      getter compaction_output_bytes : Int64
      getter table_bytes_written : Int64
      getter write_amplification : Float64

      def initialize(@tables : Int32, @l0 : Int32, @l1 : Int32, @level_counts : Array(Int32),
                     @level_bytes : Array(Int64),
                     @entries : Int64, @disk_bytes : Int64, @memtable_bytes : Int64,
                     @wal_bytes : Int64, @seq : Int64, @cache_hits : Int64, @cache_misses : Int64,
                     @writes : Int64, @commits : Int64, @logical_write_bytes : Int64,
                     @flush_bytes_written : Int64, @compaction_input_tables : Int64,
                     @compaction_input_entries : Int64, @compaction_input_bytes : Int64,
                     @compaction_output_tables : Int64, @compaction_output_entries : Int64,
                     @compaction_output_bytes : Int64, @table_bytes_written : Int64,
                     @write_amplification : Float64)
      end

      def to_h : Hash(String, Int32 | Int64 | Float64 | Array(Int32) | Array(Int64))
        {
          "tables"                    => @tables,
          "l0"                        => @l0,
          "l1"                        => @l1,
          "levels"                    => @level_counts,
          "level_bytes"               => @level_bytes,
          "entries"                   => @entries,
          "disk_bytes"                => @disk_bytes,
          "memtable_bytes"            => @memtable_bytes,
          "wal_bytes"                 => @wal_bytes,
          "seq"                       => @seq,
          "cache_hits"                => @cache_hits,
          "cache_misses"              => @cache_misses,
          "writes"                    => @writes,
          "commits"                   => @commits,
          "logical_write_bytes"       => @logical_write_bytes,
          "flush_bytes_written"       => @flush_bytes_written,
          "compaction_input_tables"   => @compaction_input_tables,
          "compaction_input_entries"  => @compaction_input_entries,
          "compaction_input_bytes"    => @compaction_input_bytes,
          "compaction_output_tables"  => @compaction_output_tables,
          "compaction_output_entries" => @compaction_output_entries,
          "compaction_output_bytes"   => @compaction_output_bytes,
          "table_bytes_written"       => @table_bytes_written,
          "write_amplification"       => @write_amplification,
        }
      end

      def to_json(io : IO) : Nil
        to_h.to_json(io)
      end

      def to_s(io : IO) : Nil
        io << "tables: #{@tables} (l0: #{@l0}, l1: #{@l1})\n"
        io << "levels: #{@level_counts}\n"
        io << "level bytes: #{@level_bytes}\n"
        io << "entries: #{@entries}\n"
        io << "disk bytes: #{@disk_bytes}\n"
        io << "memtable bytes: #{@memtable_bytes}\n"
        io << "wal bytes: #{@wal_bytes}\n"
        io << "sequence: #{@seq}\n"
        io << "cache hits: #{@cache_hits}, misses: #{@cache_misses}\n"
        io << "writes: #{@writes}, commits: #{@commits}\n"
        io << "logical write bytes: #{@logical_write_bytes}\n"
        io << "flush bytes written: #{@flush_bytes_written}\n"
        io << "compaction input: #{@compaction_input_tables} tables, #{@compaction_input_entries} entries, #{@compaction_input_bytes} bytes\n"
        io << "compaction output: #{@compaction_output_tables} tables, #{@compaction_output_entries} entries, #{@compaction_output_bytes} bytes\n"
        io << "table bytes written: #{@table_bytes_written}\n"
        io << "write amplification: #{@write_amplification}"
      end
    end

    # Results from a read-only storage verification.
    class VerificationReport
      getter tables : Int32
      getter table_entries : Int64
      getter wal_files : Int32
      getter wal_records : Int64
      getter bytes_checked : Int64
      getter errors : Array(String)

      def initialize(@tables : Int32, @table_entries : Int64, @wal_files : Int32,
                     @wal_records : Int64, @bytes_checked : Int64, @errors : Array(String))
      end

      def valid? : Bool
        @errors.empty?
      end

      def to_h : Hash(String, Bool | Int32 | Int64 | Array(String))
        {
          "valid"         => valid?,
          "tables"        => @tables,
          "table_entries" => @table_entries,
          "wal_files"     => @wal_files,
          "wal_records"   => @wal_records,
          "bytes_checked" => @bytes_checked,
          "errors"        => @errors,
        }
      end

      def to_json(io : IO) : Nil
        to_h.to_json(io)
      end

      def to_s(io : IO) : Nil
        io << "verification: #{valid? ? "valid" : "invalid"}\n"
        io << "tables: #{@tables}, table entries: #{@table_entries}\n"
        io << "wal files: #{@wal_files}, wal records: #{@wal_records}\n"
        io << "bytes checked: #{@bytes_checked}"
        @errors.each { |error| io << "\nerror: #{error}" }
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
    @logical_write_bytes : Int64 = 0_i64
    @flush_bytes_written : Int64 = 0_i64
    @compaction_input_tables : Int64 = 0_i64
    @compaction_input_entries : Int64 = 0_i64
    @compaction_input_bytes : Int64 = 0_i64
    @compaction_output_tables : Int64 = 0_i64
    @compaction_output_entries : Int64 = 0_i64
    @compaction_output_bytes : Int64 = 0_i64
    @compaction_job : Manifest::CompactionInfo? = nil
    @commit_group : CommitGroup? = nil
    @indexers : Hash(String, Proc(String, String, Array(String)))
    @index_build_lock = Mutex.new
    @index_builds : Hash(String, Manifest::IndexBuildInfo)
    @index_statuses : Hash(String, IndexBuildStatus)

    def initialize(path : String, config : Config = Config.new)
      raise ArgumentError.new("index_build_batch_size must be positive") if config.index_build_batch_size <= 0
      @path = path
      @config = config
      @mem = MemTable.new
      @levels = [[] of TableRef]
      @block_cache = BlockCache.new(config.cache_blocks)
      @indexers = {} of String => Proc(String, String, Array(String))
      @index_builds = {} of String => Manifest::IndexBuildInfo
      @index_statuses = {} of String => IndexBuildStatus
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
    # on every write. Creation also backfills existing rows.
    # Call `query` to find the primary keys that share an index key.
    def create_index(name : String, &indexer : String, String -> Array(String)) : Nil
      register_index(name, indexer)
    end

    # Registers an index that reads one JSON field from every value.
    #
    # A scalar field yields one index key. An array field yields one key
    # per element. A value that is not JSON, or that lacks the field,
    # yields no index keys. Creation backfills existing rows.
    # The indexer never fails a write.
    def create_json_index(name : String, field : String) : Nil
      raise InvalidIndexError.new("field must not be empty") if field.empty?
      indexer = ->(_key : String, value : String) { json_index_keys(value, field) }
      register_index(name, indexer, Manifest::IndexInfo.new(name, field))
    end

    # Starts a durable, resumable JSON index build.
    # The index accepts writes, but queries wait until the build is ready.
    def start_json_index(name : String, field : String) : IndexBuildStatus
      raise InvalidIndexError.new("field must not be empty") if field.empty?
      indexer = ->(_key : String, value : String) { json_index_keys(value, field) }
      build = Manifest::IndexBuildInfo.new
      register_index(name, indexer, Manifest::IndexInfo.new(name, field, build))
      index_build_status(name).not_nil!
    end

    # Advances one configured batch of a JSON index build.
    # Call this method again until the returned status is ready.
    def build_index(name : String) : IndexBuildStatus
      validate_index_name(name)
      @index_build_lock.synchronize do
        wal : Wal::Writer? = nil
        status : IndexBuildStatus? = nil
        @lock.synchronize do
          check_open
          build = @index_builds[name]?
          unless build
            status = @index_statuses[name]?
            raise InvalidIndexError.new("index is not building: #{name}") unless status
            next
          end

          indexer = @indexers[name]?.not_nil!
          entries, last_key, processed, finished = build_index_batch(name, build.last_key, indexer)
          unless entries.empty?
            @seq += 1
            entries = entries.map { |entry| Entry.new(entry.key, @seq, true, entry.value) }
            wal = @wal.not_nil!
            wal.append_batch(entries)
            apply_index_entries(entries)
            @writes += 1
          end

          build.last_key = last_key
          build.processed += processed
          build.complete = finished
          status = index_build_status_for(name, build)
        end

        commit_wal(wal.not_nil!) if wal
        @lock.synchronize do
          if build = @index_builds[name]?
            update_index_manifest(name, build)
            if build.complete
              @index_builds.delete(name)
            end
            status = @index_statuses[name] = index_build_status_for(name, build)
          end
        end
        status.not_nil!
      end
    end

    # Returns the persisted build state, or nil for an untracked index.
    def index_build_status(name : String) : IndexBuildStatus?
      validate_index_name(name)
      @lock.synchronize do
        check_open
        @index_statuses[name]?
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
        ensure_index_ready(index)
        return [] of String if limit == 0
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
        ensure_index_ready(index)
        return [] of String if limit == 0
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
    def query_iter(index : String, index_key : String, limit : Int32 = -1) : IndexIter
      validate_index_name(index)
      @lock.synchronize do
        check_open
        ensure_index_ready(index)
      end
      snap = snapshot
      begin
        iter = snap.query_iter(index, index_key, limit)
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
    def query_range_iter(index : String, start_key : String = "", finish_key : String? = nil,
                         limit : Int32 = -1) : IndexIter
      validate_index_name(index)
      @lock.synchronize do
        check_open
        ensure_index_ready(index)
      end
      snap = snapshot
      begin
        iter = snap.query_range_iter(index, start_key, finish_key, limit)
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
        @logical_write_bytes += logical_write_bytes(key, value, true)
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
        @logical_write_bytes += logical_write_bytes(key, "", false)
      end
      commit_wal(wal.not_nil!)
      trigger_flush
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
        ops.each do |key, value, alive|
          @logical_write_bytes += logical_write_bytes(key, value, alive)
        end
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
      iter = scan_prefix_iter(prefix, limit)
      result = [] of Tuple(String, String)
      begin
        while pair = iter.next?
          result << pair
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
        return [] of Tuple(String, String) if limit == 0
        collect_range(start_key, finish_key, limit)
      end
    end

    # Returns a streaming iterator over live pairs whose keys start with
    # `prefix`. The iterator owns the snapshot it creates.
    def scan_prefix_iter(prefix : String, limit : Int32 = -1) : ScanIter
      snap = snapshot
      begin
        iter = snap.scan_prefix_iter(prefix, limit)
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
    def scan_iter(start_key : String = "", finish_key : String? = nil, limit : Int32 = -1) : ScanIter
      snap = snapshot
      begin
        iter = snap.scan_iter(start_key, finish_key, limit)
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

    # Returns true while a budgeted full compaction has unfinished slices.
    # The marker survives a database restart.
    def compaction_pending? : Bool
      @lock.synchronize { !@compaction_job.nil? }
    end

    # Runs level-by-level compaction until every level is within its target.
    #
    # Level 0 merges into level 1 when it holds enough tables. Deeper levels
    # merge into the level below when they exceed their size target. Returns
    # true when any table moved. The automatic background task uses this.
    def compact_levels : Bool
      @flush_lock.synchronize do
        pending = @lock.synchronize do
          return false if @closed
          !@compaction_job.nil?
        end
        if pending
          do_compact
          return true
        end
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
        Snapshot.new(@seq, @mem.dup, @frozen, tables, @config.cache_blocks, @index_builds.keys)
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

    # Copies the live primary key/value pairs from one consistent snapshot
    # into a new database directory. The destination must not exist.
    #
    # The export streams the source snapshot and writes bounded batches. It
    # returns the number of primary rows copied. Persisted JSON index definitions
    # are copied to the destination. Custom index blocks remain process-local.
    def export(destination : String, config : Config = Config.new) : Int64
      raise Error.new("export destination already exists: #{destination}") if File.exists?(destination)

      view = snapshot
      target : DB? = nil
      iterator : ScanIter? = nil
      copied = 0_i64
      batch = Batch.new
      begin
        target = DB.new(destination, config)
        index_definitions = @lock.synchronize do
          @manifest.not_nil!.indexes.map { |definition| {definition.name, definition.field} }
        end
        index_definitions.each do |name, field|
          target.not_nil!.create_json_index(name, field)
        end
        iterator = view.scan_iter
        while pair = iterator.not_nil!.next?
          batch.put(pair[0], pair[1])
          copied += 1
          if batch.size >= EXPORT_BATCH_SIZE
            target.not_nil!.write(batch)
            batch = Batch.new
          end
        end
        target.not_nil!.write(batch) unless batch.empty?
        target.not_nil!.flush
        copied
      ensure
        iterator.try(&.close)
        view.release
        target.try(&.close)
      end
    end

    # Returns a snapshot of database counters.
    def stats : Stats
      @lock.synchronize do
        check_open
        table_refs = @levels.flatten
        level_bytes = @levels.map { |level| level.sum { |ref| file_size(ref.path) } }
        disk_bytes = level_bytes.sum
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
          level_bytes: level_bytes,
          entries: entries,
          disk_bytes: disk_bytes,
          memtable_bytes: @mem.approximate_bytes,
          wal_bytes: wal_bytes,
          seq: @seq,
          cache_hits: @block_cache.hits,
          cache_misses: @block_cache.misses,
          writes: @writes,
          commits: @commit_group.try(&.commits) || 0_i64,
          logical_write_bytes: @logical_write_bytes,
          flush_bytes_written: @flush_bytes_written,
          compaction_input_tables: @compaction_input_tables,
          compaction_input_entries: @compaction_input_entries,
          compaction_input_bytes: @compaction_input_bytes,
          compaction_output_tables: @compaction_output_tables,
          compaction_output_entries: @compaction_output_entries,
          compaction_output_bytes: @compaction_output_bytes,
          table_bytes_written: @flush_bytes_written + @compaction_output_bytes,
          write_amplification: write_amplification,
        )
      end
    end

    # Verifies a database directory without opening or recovering it.
    #
    # This entry point is safe for diagnostics because it does not remove
    # orphan files, replay logs, or create a new active log.
    def self.verify(path : String) : VerificationReport
      errors = [] of String
      table_entries = 0_i64
      bytes_checked = 0_i64
      table_infos = [] of Manifest::TableInfo
      children = begin
        Dir.children(path)
      rescue ex : Exception
        errors << "database directory: #{verification_error(ex)}"
        [] of String
      end

      manifest_path = File.join(path, MANIFEST_NAME)
      bytes_checked += verification_file_size(manifest_path)
      if File.exists?(manifest_path)
        begin
          table_infos = Manifest.load(manifest_path).levels.flatten
        rescue ex : Exception
          errors << "#{MANIFEST_NAME}: #{verification_error(ex)}"
        end
      else
        errors << "#{MANIFEST_NAME}: file is missing"
      end

      known_ids = table_infos.map(&.id)
      table_infos.each do |info|
        table_path = File.join(path, "#{Util.file_stem(info.id)}#{SST_SUFFIX}")
        bytes_checked += verification_file_size(table_path)
        reader : SstableReader? = nil
        begin
          reader = SstableReader.new(table_path, info.id)
          actual = reader.not_nil!.verify
          table_entries += actual.count
          unless actual.id == info.id && actual.first == info.first &&
                 actual.last == info.last && actual.count == info.count &&
                 actual.index_count == info.index_count
            errors << "#{File.basename(table_path)}: manifest metadata mismatch"
          end
        rescue ex : Exception
          errors << "#{File.basename(table_path)}: #{verification_error(ex)}"
        ensure
          reader.try(&.close)
        end
      end

      children.select { |name| name.ends_with?(SST_SUFFIX) }.sort.each do |name|
        id = name.rpartition(".")[0].to_i64
        unless known_ids.includes?(id)
          errors << "#{name}: table is not listed in #{MANIFEST_NAME}"
        end
      end

      wal_files = 0
      wal_records = 0_i64
      children.select { |name| name.ends_with?(WAL_SUFFIX) }.sort.each do |name|
        wal_files += 1
        wal_path = File.join(path, name)
        bytes_checked += verification_file_size(wal_path)
        begin
          wal_records += Wal.verify(wal_path)
        rescue ex : Exception
          errors << "#{name}: #{verification_error(ex)}"
        end
      end

      VerificationReport.new(table_infos.size.to_i32, table_entries, wal_files,
        wal_records, bytes_checked, errors)
    end

    # Checks every manifest table and write ahead log without changing data.
    #
    # The check waits for an active flush, then blocks writes for its duration.
    # It verifies table blocks, bloom filters, WAL framing, and manifest
    # metadata. Fast-mode files can only be checked for layout, not bit rot.
    def verify : VerificationReport
      @flush_lock.synchronize do
        @lock.synchronize do
          check_open
          errors = [] of String
          table_refs = @levels.flatten
          table_entries = 0_i64
          bytes_checked = 0_i64
          bytes_checked += file_size(File.join(@path, MANIFEST_NAME))

          table_refs.each do |ref|
            bytes_checked += file_size(ref.path)
            reader : SstableReader? = nil
            begin
              # Use a fresh reader so verification bypasses caches and does
              # not move the file position of a concurrent snapshot reader.
              reader = SstableReader.new(ref.path, ref.id)
              actual = reader.not_nil!.verify
              table_entries += actual.count
              unless actual.id == ref.id && actual.first == ref.first &&
                     actual.last == ref.last && actual.count == ref.count &&
                     actual.index_count == ref.index_count
                errors << "#{File.basename(ref.path)}: manifest metadata mismatch"
              end
            rescue ex : Exception
              errors << "#{File.basename(ref.path)}: #{verification_error(ex)}"
            ensure
              reader.try(&.close)
            end
          end

          wal_files = 0
          wal_records = 0_i64
          Dir.children(@path).select { |name| name.ends_with?(WAL_SUFFIX) }.sort.each do |name|
            wal_files += 1
            path = File.join(@path, name)
            bytes_checked += file_size(path)
            begin
              wal_records += Wal.verify(path)
            rescue ex : Exception
              errors << "#{name}: #{verification_error(ex)}"
            end
          end

          VerificationReport.new(table_refs.size.to_i32, table_entries, wal_files,
            wal_records, bytes_checked, errors)
        end
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

    # Registers an index and backfills associations for existing rows.
    private def register_index(name : String, indexer : Proc(String, String, Array(String)),
                               definition : Manifest::IndexInfo? = nil) : Nil
      validate_index_name(name)
      wal : Wal::Writer? = nil
      @lock.synchronize do
        check_open
        raise InvalidIndexError.new("index already exists: #{name}") if @indexers.has_key?(name)
        @indexers[name] = indexer
        begin
          if info = definition
            if build = info.build
              @index_builds[name] = build
              @index_statuses[name] = index_build_status_for(name, build)
            else
              wal = backfill_index(name, indexer)
              @index_statuses[name] = IndexBuildStatus.new(name, "ready", -1_i64, "")
            end
          else
            wal = backfill_index(name, indexer)
            @index_statuses[name] = IndexBuildStatus.new(name, "ready", -1_i64, "")
          end
        rescue ex
          @indexers.delete(name)
          @index_builds.delete(name)
          @index_statuses.delete(name)
          raise ex
        end
      end

      commit_wal(wal.not_nil!) if wal
      @lock.synchronize do
        check_open
        if info = definition
          @manifest.not_nil!.indexes << info
        end
        save_manifest
      end
      trigger_flush
    end

    # Collects one bounded batch of live primary rows.
    # The caller holds the database lock.
    private def build_index_batch(name : String, last_key : String,
                                  indexer : Proc(String, String, Array(String))) : Tuple(Array(Entry), String, Int64, Bool)
      iter = LiveIter.new(make_merge_iter(last_key, false))
      entries = [] of Entry
      cursor = last_key
      processed = 0_i64
      finished = true
      while entry = iter.next?
        next if !last_key.empty? && entry.key <= last_key
        raise InvalidKeyError.new("keys with a NUL byte cannot be indexed") if entry.key.includes?(Index::SEP)
        indexer.call(entry.key, entry.value).uniq.each do |index_key|
          raise InvalidIndexError.new("index key contains a NUL byte") if index_key.includes?(Index::SEP)
          next if index_key.empty?
          entries << Entry.new(Index.entry_key(name, index_key, entry.key), 0_i64, true, "")
        end
        cursor = entry.key
        processed += 1
        if processed >= @config.index_build_batch_size
          finished = false
          break
        end
      end
      {entries, cursor, processed, finished}
    end

    private def index_build_status_for(name : String, build : Manifest::IndexBuildInfo) : IndexBuildStatus
      state = build.complete ? "ready" : "building"
      IndexBuildStatus.new(name, state, build.processed, build.last_key)
    end

    private def update_index_manifest(name : String, build : Manifest::IndexBuildInfo) : Nil
      definition = @manifest.not_nil!.indexes.find { |info| info.name == name }
      raise CorruptDataError.new("index definition is missing: #{name}") unless definition
      definition.not_nil!.build = build
      save_manifest
    end

    private def ensure_index_ready(name : String) : Nil
      if status = @index_statuses[name]?
        raise IndexNotReadyError.new("index is still building: #{name}") unless status.ready?
      end
    end

    # Reconciles one index with the current live primary rows.
    #
    # The caller holds the database lock. Missing associations become live
    # entries. Stale associations become tombstones in one WAL batch.
    private def backfill_index(name : String, indexer : Proc(String, String, Array(String))) : Wal::Writer?
      desired = {} of String => Bool
      collect_range("", nil, -1).each do |key, value|
        raise InvalidKeyError.new("keys with a NUL byte cannot be indexed") if key.includes?(Index::SEP)
        indexer.call(key, value).each do |index_key|
          raise InvalidIndexError.new("index key for #{name} contains a NUL byte") if index_key.includes?(Index::SEP)
          next if index_key.empty?
          desired[Index.entry_key(name, index_key, key)] = true
        end
      end

      existing = {} of String => Bool
      prefix = Index.name_prefix(name)
      iter = make_merge_iter(prefix, false)
      while entry = iter.next?
        break unless entry.key.starts_with?(prefix)
        existing[entry.key] = true if entry.alive
      end

      pending = [] of Tuple(String, Bool)
      desired.each_key do |entry_key|
        pending << {entry_key, true} unless existing.has_key?(entry_key)
      end
      existing.each_key do |entry_key|
        pending << {entry_key, false} unless desired.has_key?(entry_key)
      end
      return nil if pending.empty?

      @seq += 1
      seq = @seq
      entries = [] of Entry
      pending.each do |entry_key, alive|
        entries << Entry.new(entry_key, seq, alive, "")
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
      wal
    end

    # Extracts keys from one JSON field without failing a write.
    private def json_index_keys(value : String, field : String) : Array(String)
      doc = JSON.parse(value)
      Index.json_field_keys(doc, field)
    rescue JSON::ParseException
      [] of String
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
      @compaction_job = manifest.compaction
      load_indexers(manifest)
      load_tables(manifest)
      clean_orphans
      recover_wals
      create_active_wal
    end

    # Restores JSON indexers recorded in the manifest.
    private def load_indexers(manifest : Manifest) : Nil
      manifest.indexes.each do |definition|
        validate_index_name(definition.name)
        raise CorruptDataError.new("persisted index field must not be empty") if definition.field.empty?
        raise CorruptDataError.new("duplicate persisted index: #{definition.name}") if @indexers.has_key?(definition.name)
        @indexers[definition.name] = ->(_key : String, value : String) { json_index_keys(value, definition.field) }
        if build = definition.build
          @index_statuses[definition.name] = index_build_status_for(definition.name, build)
          @index_builds[definition.name] = build unless build.complete
        else
          @index_statuses[definition.name] = IndexBuildStatus.new(definition.name, "ready", -1_i64, "")
        end
      end
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
      if job = @manifest.try(&.compaction)
        known.concat(job.output_ids)
      end
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
        @flush_bytes_written += file_size(table_path(meta.id))
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

    # Writes a completed output slice before its manifest marker advances.
    private def write_entries_to_table(table_id : Int64, entries : Array(Entry)) : TableMeta
      tmp_path = File.join(@path, "#{Util.file_stem(table_id)}#{TMP_SUFFIX}")
      final_path = table_path(table_id)
      meta = nil
      File.open(tmp_path, "w") do |io|
        writer = SstableWriter.new(io, table_id, @config.block_size, @config.bloom_fpp, @config.checksums)
        entries.each { |entry| writer.add(entry.key, entry.value, entry.seq, entry.alive) }
        meta = writer.finish
        io.flush
        io.fsync if @config.sync_writes
      end
      File.rename(tmp_path, final_path)
      meta.not_nil!
    end

    # Reserves a table id before writing a resumable output file.
    private def allocate_compaction_table_id : Int64
      @lock.synchronize do
        id = @next_id
        @next_id += 1
        save_manifest
        id
      end
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
    # A positive budget persists the merge between calls and restarts.
    private def do_compact : Nil
      pending = @lock.synchronize { !@compaction_job.nil? }
      if pending || @config.compaction_work_budget > 0
        do_compact_slice(@config.compaction_work_budget)
      else
        do_full_compact
      end
    end

    # Runs one resumable compaction slice. Source tables stay in the manifest
    # until the final slice swaps the completed output into the live levels.
    private def do_compact_slice(work_budget : Int32) : Nil
      job : Manifest::CompactionInfo? = nil
      inputs : Array(TableRef)? = nil
      @lock.synchronize do
        return if @closed
        job = @compaction_job
        unless job
          tables = @levels.flatten
          return if tables.size < 2
          job = Manifest::CompactionInfo.new(tables.map(&.id))
          @compaction_job = job
          @manifest.not_nil!.compaction = job
          save_manifest
        end
        inputs = compaction_inputs(job.not_nil!)
      end

      current_job = job.not_nil!
      current_inputs = inputs.not_nil!
      if current_job.finished
        @lock.synchronize do
          current = @compaction_job
          finalize_compaction(current.not_nil!, compaction_inputs(current.not_nil!)) if current
        end
        return
      end

      entries, last_key, finished = merge_compaction_slice(current_inputs, current_job.last_key, work_budget)
      output : TableMeta? = nil
      unless entries.empty?
        table_id = allocate_compaction_table_id
        output = write_entries_to_table(table_id, entries)
      end

      @lock.synchronize do
        current = @compaction_job
        raise CorruptDataError.new("compaction marker changed during compaction") unless current
        current.output_ids << output.not_nil!.id if output
        current.last_key = last_key
        current.finished = finished
        save_manifest
        finalize_compaction(current, compaction_inputs(current)) if current.finished
      end
    end

    # Returns the input references named by a durable compaction marker.
    # The caller holds the database lock.
    private def compaction_inputs(job : Manifest::CompactionInfo) : Array(TableRef)
      refs = @levels.flatten
      job.input_ids.map do |id|
        ref = refs.find { |candidate| candidate.id == id }
        raise CorruptDataError.new("compaction input table is missing: #{id}") unless ref
        ref
      end
    end

    # Produces one ordered output slice and returns its resume key.
    private def merge_compaction_slice(tables : Array(TableRef), last_key : String,
                                       work_budget : Int32) : Tuple(Array(Entry), String, Bool)
      readers = @lock.synchronize { tables.map { |ref| ref.reader(@block_cache) } }
      sources = [] of Store::Iter
      readers.each { |reader| sources << TableIter.new(reader) }
      iter = MergeIter.new(sources)
      iter.seek(last_key) unless last_key.empty?

      entries = [] of Entry
      processed = 0
      resume_key = last_key
      while entry = iter.next?
        next if !last_key.empty? && entry.key <= last_key
        processed += 1
        resume_key = entry.key
        entries << entry if entry.alive
        if work_budget > 0 && processed >= work_budget
          return {entries, resume_key, false}
        end
      end
      {entries, resume_key, true}
    end

    # Finishes a marker whose output files are already complete. The caller
    # holds the database lock.
    private def finalize_compaction(job : Manifest::CompactionInfo, inputs : Array(TableRef)) : Nil
      outputs = job.output_ids.map do |id|
        reader = SstableReader.new(table_path(id), id)
        begin
          reader.verify
        ensure
          reader.close
        end
      end
      output_refs = outputs.map do |meta|
        TableRef.new(meta.id, meta.first, meta.last, meta.count, table_path(meta.id), meta.index_count)
      end

      kept_levels = [[] of TableRef, [] of TableRef]
      input_ids = job.input_ids
      @levels.each_with_index do |level, level_index|
        level.each do |ref|
          next if input_ids.includes?(ref.id)
          target_level = level_index == 0 ? 0 : 1
          kept_levels[target_level] << ref
        end
      end
      kept_levels[1].concat(output_refs)
      kept_levels[1].sort_by!(&.first)
      @levels = kept_levels

      record_compaction(inputs, outputs)
      @compaction_job = nil
      @manifest.not_nil!.compaction = nil
      save_manifest

      inputs.each do |ref|
        # Mark the table as gone, then drop the database reference. The file
        # stays on disk until every snapshot reference is released.
        ref.orphan
        ref.release
      end
    end

    # The original one-pass compaction path for an unlimited budget.
    private def do_full_compact : Nil
      tables = nil
      @lock.synchronize do
        return if @closed
        tables = @levels.flatten
        return if tables.size < 2
      end

      outputs = merge_tables(tables.not_nil!, true)

      @lock.synchronize do
        record_compaction(tables.not_nil!, outputs)
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
        record_compaction(inputs, outputs)
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

    # Records completed compaction work while input files still exist.
    private def record_compaction(inputs : Array(TableRef), outputs : Array(TableMeta)) : Nil
      @compaction_input_tables += inputs.size
      @compaction_input_entries += inputs.sum(&.count)
      @compaction_input_bytes += inputs.sum { |ref| file_size(ref.path) }
      @compaction_output_tables += outputs.size
      @compaction_output_entries += outputs.sum(&.count)
      @compaction_output_bytes += outputs.sum { |meta| file_size(table_path(meta.id)) }
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

    # Returns bytes in table files written per logical primary write byte.
    private def write_amplification : Float64
      return 0.0 if @logical_write_bytes == 0
      (@flush_bytes_written + @compaction_output_bytes).to_f / @logical_write_bytes
    end

    # Counts primary key and value bytes for one user write.
    private def logical_write_bytes(key : String, value : String, alive : Bool) : Int64
      key.bytesize.to_i64 + (alive ? value.bytesize.to_i64 : 0_i64)
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

    private def verification_error(error : Exception) : String
      error.message || error.class.to_s
    end

    private def self.verification_error(error : Exception) : String
      error.message || error.class.to_s
    end

    private def self.verification_file_size(path : String) : Int64
      File.size(path)
    rescue File::NotFoundError
      0_i64
    end
  end
end
