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
      # Number of level-0 tables that trigger compaction.
      property l0_compact_threshold : Int32 = 4
      # Start background compaction after a flush when true.
      property compact_on_flush : Bool = true
      # Size target for level one. A full level compacts into the level below.
      property level_target_bytes : Int64 = 8_i64 * 1024 * 1024
      # Size growth factor between consecutive levels.
      property level_ratio : Int32 = 10
      # Maximum number of levels, including level zero.
      property max_levels : Int32 = 7
    end

    # A snapshot of database counters for reporting.
    class Stats
      getter tables : Int32
      getter l0 : Int32
      getter l1 : Int32
      getter levels : Array(Int32)
      getter entries : Int64
      getter disk_bytes : Int64
      getter memtable_bytes : Int64
      getter wal_bytes : Int64
      getter seq : Int64
      getter cache_hits : Int64
      getter cache_misses : Int64

      def initialize(@tables : Int32, @l0 : Int32, @l1 : Int32, @levels : Array(Int32),
                     @entries : Int64, @disk_bytes : Int64, @memtable_bytes : Int64,
                     @wal_bytes : Int64, @seq : Int64, @cache_hits : Int64, @cache_misses : Int64)
      end

      def to_h : Hash(String, Int32 | Int64 | Array(Int32))
        {
          "tables"         => @tables,
          "l0"             => @l0,
          "l1"             => @l1,
          "levels"         => @levels,
          "entries"        => @entries,
          "disk_bytes"     => @disk_bytes,
          "memtable_bytes" => @memtable_bytes,
          "wal_bytes"      => @wal_bytes,
          "seq"            => @seq,
          "cache_hits"     => @cache_hits,
          "cache_misses"   => @cache_misses,
        }
      end

      def to_json(io : IO) : Nil
        to_h.to_json(io)
      end

      def to_s(io : IO) : Nil
        io << "tables: #{@tables} (l0: #{@l0}, l1: #{@l1})\n"
        io << "levels: #{@levels.join(", ")}\n"
        io << "entries: #{@entries}\n"
        io << "disk bytes: #{@disk_bytes}\n"
        io << "memtable bytes: #{@memtable_bytes}\n"
        io << "wal bytes: #{@wal_bytes}\n"
        io << "sequence: #{@seq}\n"
        io << "cache hits: #{@cache_hits}, misses: #{@cache_misses}"
      end
    end

    # A live reference to one sorted table file.
    class TableRef
      getter id : Int64
      getter first : String
      getter last : String
      getter count : Int64
      getter path : String

      @reader : SstableReader?
      @refs : Int32 = 1
      @orphaned : Bool = false

      def initialize(@id : Int64, @first : String, @last : String, @count : Int64, @path : String)
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

    def initialize(path : String, config : Config = Config.new)
      @path = path
      @config = config
      @mem = MemTable.new
      @levels = [[] of TableRef]
      @block_cache = BlockCache.new(config.cache_blocks)
      open
    end

    def path : String
      @path
    end

    # Writes a value for `key`.
    def put(key : String, value : String) : Nil
      validate_key(key)
      raise InvalidValueError.new("value exceeds #{MAX_VALUE_BYTES} bytes") if value.bytesize > MAX_VALUE_BYTES
      @lock.synchronize do
        check_open
        @seq += 1
        @wal.not_nil!.append(Entry.new(key, @seq, true, value))
        @mem.put(key, value, @seq)
      end
      trigger_flush
    end

    # Writes a tombstone for `key`.
    def delete(key : String) : Nil
      validate_key(key)
      @lock.synchronize do
        check_open
        @seq += 1
        @wal.not_nil!.append(Entry.new(key, @seq, false, ""))
        @mem.delete(key, @seq)
      end
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

    # Returns live key/value pairs in key order. The range is [start, finish).
    # A negative limit means no limit.
    def scan(start_key : String = "", finish_key : String? = nil, limit : Int32 = -1) : Array(Tuple(String, String))
      @lock.synchronize do
        check_open
        collect_range(start_key, finish_key, limit)
      end
    end

    # Flushes the active memtable to a new sorted table.
    def flush : Nil
      @flush_lock.synchronize do
        do_flush
      end
      trigger_compact
    end

    # Compacts the level that needs it most.
    #
    # A compact moves one level of tables into the level below. It merges
    # the source tables with the tables below that overlap them. Level zero
    # compacts first when it holds several tables. Deeper levels compact
    # when their size passes the level target.
    def compact : Nil
      @flush_lock.synchronize do
        do_compact
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
        entries = table_refs.sum(&.count) + @mem.size + (@frozen.try(&.size) || 0_i64)
        wal_bytes = 0_i64
        Dir.children(@path).each do |name|
          wal_bytes += file_size(File.join(@path, name)) if name.ends_with?(WAL_SUFFIX)
        end
        Stats.new(
          tables: table_refs.size,
          l0: @levels[0].size,
          l1: @levels.size > 1 ? @levels[1].size : 0,
          levels: @levels.map(&.size),
          entries: entries,
          disk_bytes: disk_bytes,
          memtable_bytes: @mem.approximate_bytes,
          wal_bytes: wal_bytes,
          seq: @seq,
          cache_hits: @block_cache.hits,
          cache_misses: @block_cache.misses,
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
          TableRef.new(info.id, info.first, info.last, info.count, table_path(info.id))
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
      @wal = Wal::Writer.new(wal_path(id), @config.sync_writes)
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
          @wal = Wal::Writer.new(wal_path(wal_id), @config.sync_writes)
        end
      end

      table_id = @pending_table_id
      frozen = @frozen.not_nil!
      meta = write_memtable_to_table(table_id, frozen)

      @lock.synchronize do
        @levels[0] << TableRef.new(meta.id, meta.first, meta.last, meta.count, table_path(meta.id))
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
        writer = SstableWriter.new(io, table_id, @config.block_size, @config.bloom_fpp)
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

    private def trigger_compact : Nil
      return unless @config.compact_on_flush
      return unless needs_compact?
      return if @compacting
      @compacting = true
      spawn do
        begin
          compact
        ensure
          @compacting = false
        end
      end
    end

    # ------------------------------------------------------------------
    # Compaction
    # ------------------------------------------------------------------

    # One planned merge: the tables to read and where to write them.
    private record CompactionStep, level : Int32, output_level : Int32,
      sources : Array(TableRef), drop_tombstones : Bool

    private def do_compact : Nil
      step = nil
      @lock.synchronize do
        return if @closed
        step = pick_compaction_step
      end
      return unless step
      compact_step(step.not_nil!)
    end

    # Selects the level that needs compaction next.
    #
    # Level zero compacts first when it holds enough tables. Otherwise the
    # shallowest level whose size passes its target compacts. An explicit
    # compact also moves a small level zero into level one.
    private def pick_compaction_step : CompactionStep?
      if @levels[0].size >= @config.l0_compact_threshold
        return level0_step
      end
      if level = next_overflowing_level
        return level_step(level)
      end
      return level0_step unless @levels[0].empty?
      nil
    end

    private def level0_step : CompactionStep?
      return nil if @levels[0].empty?
      sources = @levels[0].dup
      range_start = sources.map(&.first).min
      range_finish = sources.map(&.last).max
      sources.concat(overlapping_tables(1, range_start, range_finish))
      CompactionStep.new(0, 1, sources, deepest_level <= 1)
    end

    private def level_step(level : Int32) : CompactionStep?
      output = (level + 1) < @config.max_levels ? level + 1 : level
      sources = @levels[level].dup
      return nil if sources.empty?
      range_start = sources.map(&.first).min
      range_finish = sources.map(&.last).max
      sources.concat(overlapping_tables(output, range_start, range_finish)) unless output == level
      CompactionStep.new(level, output, sources, deepest_level <= output)
    end

    # Returns the shallowest level above zero that passes its size target.
    private def next_overflowing_level : Int32?
      (1...@levels.size).each do |level|
        return level if !@levels[level].empty? && level_bytes(level) >= target_bytes(level)
      end
      nil
    end

    # Returns the index of the deepest level that holds a table, or -1.
    private def deepest_level : Int32
      i = @levels.size - 1
      while i >= 0
        return i unless @levels[i].empty?
        i -= 1
      end
      -1
    end

    private def needs_compact? : Bool
      return true if @levels[0].size >= @config.l0_compact_threshold
      !next_overflowing_level.nil?
    end

    private def target_bytes(level : Int32) : Int64
      @config.level_target_bytes.to_i64 * (@config.level_ratio.to_i64 ** (level - 1))
    end

    private def level_bytes(level : Int32) : Int64
      return 0_i64 if level >= @levels.size
      @levels[level].sum { |ref| file_size(ref.path) }
    end

    # Returns the tables of a level that overlap `[start, finish]`.
    #
    # Tables in a level sort by first key and never overlap. The first
    # table whose range touches the input range starts the run. Every table
    # after it is a candidate until a table starts past the finish key.
    private def overlapping_tables(level : Int32, start : String, finish : String) : Array(TableRef)
      tables = level < @levels.size ? @levels[level] : [] of TableRef
      result = [] of TableRef
      found = false
      tables.each do |table|
        if found
          break if table.first > finish
          result << table
        elsif table.last >= start
          found = true
          result << table
        end
      end
      result
    end

    # Executes one planned compaction.
    private def compact_step(step : CompactionStep) : Nil
      sources = step.sources
      if sources.size == 1
        return if step.level == step.output_level
        move_table(sources.first, step.output_level)
        return
      end

      readers = @lock.synchronize { sources.map { |ref| ref.reader(@block_cache) } }
      iter = [] of Store::Iter
      readers.each { |reader| iter << TableIter.new(reader) }
      outputs = write_merged_tables(MergeIter.new(iter), step.drop_tombstones)

      @lock.synchronize do
        return if @closed
        sources.each { |ref| remove_ref(ref) }
        outputs.each { |meta| append_table(step.output_level, meta) }
        save_manifest
        sources.each do |ref|
          # Mark the table as gone, then drop the database reference. The
          # file stays on disk until every snapshot reference is released.
          ref.orphan
          ref.release
        end
      end
    end

    # Moves a lone table into the next level without rewriting it.
    #
    # A table moves only when nothing below overlaps it. The move keeps the
    # level disjoint and avoids an unnecessary disk rewrite.
    private def move_table(ref : TableRef, level : Int32) : Nil
      @lock.synchronize do
        return if @closed
        remove_ref(ref)
        grow_levels(level)
        index = @levels[level].index { |table| table.first > ref.first } || @levels[level].size
        @levels[level].insert(index, ref)
        save_manifest
      end
    end

    # Removes a table reference from every level.
    private def remove_ref(ref : TableRef) : Nil
      @levels.each { |level| level.delete(ref) }
    end

    # Appends a freshly written table to a level.
    #
    # The merge yields keys in ascending order, so the output tables are
    # sorted and disjoint. Appending preserves that order.
    private def append_table(level : Int32, meta : TableMeta) : Nil
      grow_levels(level)
      @levels[level] << TableRef.new(meta.id, meta.first, meta.last, meta.count, table_path(meta.id))
    end

    private def grow_levels(level : Int32) : Nil
      while @levels.size <= level
        @levels << [] of TableRef
      end
    end

    # Merges a stream of entries into fresh tables for the next level.
    #
    # The merge keeps the newest entry for each key. A tombstone is written
    # through when a deeper level still holds data. It is dropped only when
    # the output level is the deepest, because nothing older can hide below.
    private def write_merged_tables(iter : MergeIter, drop_tombstones : Bool) : Array(TableMeta)
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
        next if !entry.alive && drop_tombstones
        if writer.nil?
          current_id = @lock.synchronize do
            id = @next_id
            @next_id += 1
            id
          end
          io = File.open(File.join(@path, "#{Util.file_stem(current_id)}#{TMP_SUFFIX}"), "w")
          writer = SstableWriter.new(io.not_nil!, current_id, @config.block_size, @config.bloom_fpp)
        end
        writer.not_nil!.add(entry.key, entry.value, entry.seq, entry.alive)
        written += 1
        finish_output.call if written >= MAX_TABLE_ENTRIES
      end
      finish_output.call
      outputs
    end

    # ------------------------------------------------------------------
    # Manifest and paths
    # ------------------------------------------------------------------

    private def save_manifest : Nil
      manifest = @manifest.not_nil!
      manifest.seq = @seq
      manifest.next_id = @next_id
      manifest.levels = trimmed_levels.map do |level|
        level.map do |ref|
          Manifest::TableInfo.new(ref.id, ref.first, ref.last, ref.count)
        end
      end
      manifest.save(File.join(@path, MANIFEST_NAME))
    end

    # Returns the levels without trailing empty levels.
    private def trimmed_levels : Array(Array(TableRef))
      levels = @levels.dup
      while levels.size > 1 && levels.last.empty?
        levels.pop
      end
      levels
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
