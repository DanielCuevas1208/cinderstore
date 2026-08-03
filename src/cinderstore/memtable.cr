module Cinderstore
  # The in-memory write buffer.
  #
  # The memtable holds the newest entry for each key. It keeps an
  # approximate byte count so the database can decide when to flush.
  class MemTable
    # Fixed per-entry overhead used for the byte estimate.
    OVERHEAD = 64_i64

    @table : SkipList
    @bytes : Int64 = 0_i64
    @count : Int64 = 0_i64

    def initialize(rng : Random = Random.new)
      @table = SkipList.new(rng)
    end

    def empty? : Bool
      @table.empty?
    end

    def size : Int64
      @count
    end

    def approximate_bytes : Int64
      @bytes
    end

    # Writes a live value for `key`. Overwrites any previous entry.
    def put(key : String, value : String, seq : Int64) : Nil
      prev = @table.get(key)
      if prev
        @bytes += value.bytesize - prev.value.bytesize
      else
        @bytes += key.bytesize + value.bytesize + OVERHEAD
        @count += 1
      end
      @table.insert(key, seq, true, value)
    end

    # Writes a tombstone for `key`.
    def delete(key : String, seq : Int64) : Nil
      prev = @table.get(key)
      if prev
        @bytes -= prev.value.bytesize if prev.alive
      else
        @bytes += key.bytesize + OVERHEAD
        @count += 1
      end
      @table.insert(key, seq, false, "")
    end

    # Returns the live value for `key`, or nil.
    def get(key : String) : String?
      node = @table.get(key)
      return nil unless node
      return nil unless node.alive
      node.value
    end

    # Returns the newest entry for `key`, or nil. Tombstones are returned.
    def get_entry(key : String) : Entry?
      node = @table.get(key)
      return nil unless node
      Entry.new(node.key, node.seq, node.alive, node.value)
    end

    # Yields every entry with key >= `start_key` in ascending order.
    def each_from(start_key : String, &block : Entry ->) : Nil
      node = @table.lower_bound(start_key)
      while node
        yield Entry.new(node.key, node.seq, node.alive, node.value)
        node = node.forward[0]
      end
    end

    # Yields every entry in ascending order.
    def each_entry(&block : Entry ->) : Nil
      each_from("", &block)
    end

    # Returns the node for the first key >= `start_key`. Used by iterators.
    def lower_bound(start_key : String) : SkipList::Node?
      @table.lower_bound(start_key)
    end
  end
end
