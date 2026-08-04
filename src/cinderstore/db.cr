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
      # Write a CRC32 guard per record and per block when true.
      # Set to false to skip checksum work at the cost of corruption
      # detection.
      property checksums : Bool = true
      # Number of level-0 tables that trigger compaction.
      property l0_compact_threshold : Int32 = 4
      # Start background compaction after a flush when true.
      property compact_on_flush : Bool = true
    end

    # A snapshot of database counters for reporting.
    class Stats
      getter tables : Int32
      getter l0 : Int32
      getter l1 : Int32
      getter entries : Int64
      getter disk_bytes : Int64
      getter memtable_bytes : Int64
      getter wal_bytes : Int64
      getter seq : Int64
      getter cache_hits : Int64
      getter cache_misses : Int64

      def initialize(@tables : Int32, @l0 : Int32, @l1 : Int32, @entries : Int64,
                     @disk_bytes : Int64, @memtable_bytes : Int64, @wal_bytes : Int64,
                     @seq : Int64, @cache_hits : Int64, @cache_misses : Int64)
      end

      def to_h : Hash(String, Int32 | Int64)
        {
          "tables"         => @tables,
          "l0"             => @l0,
          "l1"             => @l1,
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

    # Merges all tables into a fresh, non-overlapping level-1 set.
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
      tables = nil
      @lock.synchronize do
        return if @closed
        tables = @levels.flatten
        return if tables.size < 2
      end

      outputs = merge_tables(tables.not_nil!)

      @lock.synchronize do
        @levels = [[] of TableRef, outputs.map { |m| TableRef.new(m.id, m.first, m.last, m.count, table_path(m.id)) }]
        save_manifest
        tables.not_nil!.each do |ref|
          # Mark the table as gone, then drop the database reference. The
          # file stays on disk until every snapshot reference is released.
          ref.orphan
          ref.release
        end
      end
    end

    # Merges every table into fresh tables and drops tombstones.
    private def merge_tables(tables : Array(TableRef)) : Array(TableMeta)
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
        next unless entry.alive
        if writer.nil?
          current_id = @lock.synchronize do
            id = @next_id
            @next_id += 1
            id
          end
          io = File.open(File.join(@path, "#{Util.file_stem(current_id)}#{TMP_SUFFIX}"), "w")
          writer = SstableWriter.new(io.not_nil!, current_id, @config.block_size, @config.bloom_fpp, @config.checksums)
        end
        writer.not_nil!.add(entry.key, entry.value, entry.seq, true)
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
