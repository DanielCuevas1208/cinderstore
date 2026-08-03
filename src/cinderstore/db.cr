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
      # Number of tables in a level that trigger a merge into the next level.
      property l1_compact_threshold : Int32 = 4
      # Deepest level that compaction may write into.
      property max_level : Int32 = 6
      # Start background compaction after a flush when true.
      property compact_on_flush : Bool = true
    end

    # A snapshot of database counters for reporting.
    class Stats
      getter tables : Int32
      # Count of tables per level. Index zero is level 0.
      getter levels : Array(Int32)
      getter l0 : Int32
      getter l1 : Int32
      getter l2 : Int32
      getter l3 : Int32
      getter entries : Int64
      getter disk_bytes : Int64
      getter memtable_bytes : Int64
      getter wal_bytes : Int64
      getter seq : Int64
      getter cache_hits : Int64
      getter cache_misses : Int64

      def initialize(@tables : Int32, @levels : Array(Int32), @entries : Int64,
                     @disk_bytes : Int64, @memtable_bytes : Int64, @wal_bytes : Int64,
                     @seq : Int64, @cache_hits : Int64, @cache_misses : Int64)
        @l0 = @levels.size > 0 ? @levels[0] : 0
        @l1 = @levels.size > 1 ? @levels[1] : 0
        @l2 = @levels.size > 2 ? @levels[2] : 0
        @l3 = @levels.size > 3 ? @levels[3] : 0
      end

      def to_h : Hash(String, Int32 | Int64 | Array(Int32))
        {
          "tables"         => @tables,
          "levels"         => @levels,
          "l0"             => @l0,
          "l1"             => @l1,
          "l2"             => @l2,
          "l3"             => @l3,
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
        io << "tables: #{@tables} (levels: #{@levels})\n"
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
        if entry = @frozen.try { |m| m.get_entry(key) }
          return entry.alive ? entry.value : nil
        end
        if entry = @mem.get_entry(key)
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

    # Merges all tables into a fresh, non-overlapping level-1 set.
    def compact : Nil
      @flush_lock.synchronize do
        do_compact
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
      return if @levels[0].size < @config.l0_compact_threshold
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

    private def do_compact : Nil
      loop do
        level = @lock.synchronize do
          return if @closed
          select_compaction_level
        end
        break unless level
        break unless compact_level(level)
      end
    end

    # Returns the topmost level that needs compaction, or nil.
    #
    # Level 0 compacts once it holds two tables. An explicit compact merges
    # the newest level-0 pair even below the background threshold. Deeper
    # levels compact when they grow past `l1_compact_threshold`.
    private def select_compaction_level : Int32?
      l0 = @levels[0].size
      return 0 if l0 >= @config.l0_compact_threshold || l0 >= 2
      (1...@levels.size).each do |i|
        next if i + 1 >= @config.max_level
        return i if @levels[i].size >= @config.l1_compact_threshold
      end
      nil
    end

    # Merges every table in `level` with the overlapping tables of the
    # next level. Outputs go to the next level. Tables that do not overlap
    # the source ranges stay in place, so compaction only rewrites the part
    # of the store it must touch. Returns false when there is nothing to
    # merge.
    private def compact_level(level : Int32) : Bool
      sources, overlaps = @lock.synchronize do
        return false if @closed
        src = @levels[level]
        tgt = @levels[level + 1]? || ([] of TableRef)
        ovl = tgt.select { |ref| overlaps_any?(ref, src) }
        {src, ovl}
      end

      to_merge = sources + overlaps
      return false if to_merge.size < 2

      # A tombstone is safe to drop only when the merge covers every table
      # that could hold an older value for its key. That holds only when
      # this level feeds the deepest existing level.
      drop_tombstones = (level + 1) >= @levels.size - 1
      outputs = merge_tables(to_merge, drop_tombstones)

      @lock.synchronize do
        return false if @closed
        while @levels.size <= level + 1
          @levels << [] of TableRef
        end
        to_merge.each(&.close)
        @levels[level] = [] of TableRef
        kept = @levels[level + 1].reject { |ref| overlaps_any?(ref, sources) }
        @levels[level + 1] = kept + outputs.map { |m| TableRef.new(m.id, m.first, m.last, m.count, table_path(m.id)) }
        to_merge.each do |ref|
          File.delete(ref.path) if File.exists?(ref.path)
        end
        save_manifest
        true
      end
    end

    # Returns true when the key ranges of `ref` and any table in `others`
    # overlap. Ranges are inclusive, so touching boundaries count as an
    # overlap. A conservative answer is safe: it rewrites more, never less.
    private def overlaps_any?(ref : TableRef, others : Array(TableRef)) : Bool
      others.any? { |other| ref.first <= other.last && other.first <= ref.last }
    end

    # Merges tables into fresh tables and drops tombstones when allowed.
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
          writer = SstableWriter.new(io.not_nil!, current_id, @config.block_size, @config.bloom_fpp)
        end
        writer.not_nil!.add(entry.key, entry.value, entry.seq, drop_tombstones ? true : entry.alive)
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
      manifest.levels = @levels.map do |level|
        level.map do |ref|
          Manifest::TableInfo.new(ref.id, ref.first, ref.last, ref.count)
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
