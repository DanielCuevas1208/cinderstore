module Cinderstore
  # An immutable point-in-time view of the database.
  #
  # A snapshot copies the active memory table and keeps the table files it
  # references alive. Writes, flushes, and compactions after the snapshot
  # do not change what the snapshot sees. Release the snapshot with
  # `release` when you are done with it. Close snapshot iterators before
  # you release the snapshot.
  class Snapshot
    getter seq : Int64

    @lock = Mutex.new
    @released : Bool = false
    @readers = {} of DB::TableRef => SstableReader

    def initialize(@seq : Int64, @mem : MemTable, @frozen : MemTable?,
                   @tables : Array(Array(DB::TableRef)), cache_blocks : Int32, @checksums : Bool = true)
      @block_cache = BlockCache.new(cache_blocks)
      @tables.flatten.each(&.retain)
    end

    def released? : Bool
      @released
    end

    # Returns the live value for `key`, or nil. The value is the one the
    # store held when the snapshot was created.
    def get(key : String) : String?
      validate_key(key)
      @lock.synchronize do
        check_released
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

    # Returns live key/value pairs in key order. The range is [start, finish).
    # A negative limit means no limit.
    def scan(start_key : String = "", finish_key : String? = nil, limit : Int32 = -1) : Array(Tuple(String, String))
      @lock.synchronize do
        check_released
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
    end

    # Yields live key/value pairs in key order. The range is [start, finish).
    def each(start_key : String = "", finish_key : String? = nil, &block : String, String ->) : Nil
      scan(start_key, finish_key).each { |key, value| yield key, value }
    end

    # Returns a live iterator over the snapshot, starting at `start_key`.
    #
    # The iterator stays consistent while the database keeps writing. Close
    # the iterator before you release the snapshot.
    def iter(start_key : String = "") : Store::Iter
      @lock.synchronize do
        check_released
        SnapshotIter.new(self, LiveIter.new(make_merge_iter(start_key, false)))
      end
    end

    # Returns the number of live entries the snapshot sees. The count never
    # changes after creation.
    def count : Int64
      scan.size.to_i64
    end

    # Releases the table files this snapshot holds.
    #
    # Any later operation raises `SnapshotReleasedError`. Releasing twice
    # is a no-op.
    def release : Nil
      @lock.synchronize do
        return if @released
        @released = true
        @readers.each_value(&.close)
        @readers.clear
        @tables.flatten.each(&.release)
      end
    end

    def close : Nil
      release
    end

    # ------------------------------------------------------------------
    # Read path
    # ------------------------------------------------------------------

    private def make_merge_iter(start : String, bloom_guard : Bool) : MergeIter
      sources = [] of Store::Iter
      sources << MemIter.new(@mem, start)
      if frozen = @frozen
        sources << MemIter.new(frozen, start)
      end
      @tables.flatten.each do |ref|
        reader = reader_for(ref)
        if bloom_guard && !reader.bloom_may_contain?(start)
          next
        end
        sources << TableIter.new(reader, start)
      end
      MergeIter.new(sources)
    end

    # Returns this snapshot's reader for a table, opening it on first use.
    #
    # The reader is separate from the database reader. It lets the snapshot
    # keep reading a table file after compaction replaces it.
    private def reader_for(ref : DB::TableRef) : SstableReader
      reader = @readers[ref]?
      unless reader
        reader = SstableReader.new(ref.path, ref.id, @block_cache, @checksums)
        @readers[ref] = reader
      end
      reader
    end

    private def validate_key(key : String) : Nil
      raise InvalidKeyError.new("key must not be empty") if key.empty?
      raise InvalidKeyError.new("key exceeds #{DB::MAX_KEY_BYTES} bytes") if key.bytesize > DB::MAX_KEY_BYTES
    end

    private def check_released : Nil
      raise SnapshotReleasedError.new("snapshot is released") if @released
    end
  end

  # Advances a snapshot iterator while holding the snapshot lock.
  #
  # The iterator shares the snapshot's readers. Each step must be
  # serialized, so the snapshot lock guards every advance. The lock also
  # keeps a release from closing the readers mid-iteration.
  class SnapshotIter < Store::Iter
    def initialize(@snapshot : Snapshot, @inner : Store::Iter)
    end

    def seek(key : String) : Nil
      @snapshot.@lock.synchronize do
        raise SnapshotReleasedError.new("snapshot is released") if @snapshot.@released
        @inner.seek(key)
      end
    end

    def next? : Entry?
      @snapshot.@lock.synchronize do
        raise SnapshotReleasedError.new("snapshot is released") if @snapshot.@released
        @inner.next?
      end
    end

    def close : Nil
      @inner.close
    end
  end
end
