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
    @index_count : Int64 = 0_i64

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

    # Returns how many held entries belong to the internal index namespace.
    def index_count : Int64
      @index_count
    end

    # Writes a live value for `key`. Overwrites any previous entry.
    def put(key : String, value : String, seq : Int64) : Nil
      prev = @table.get(key)
      if prev
        @bytes += value.bytesize - prev.value.bytesize
      else
        @bytes += key.bytesize + value.bytesize + OVERHEAD
        @count += 1
        @index_count += 1 if Index.internal_key?(key)
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
        @index_count += 1 if Index.internal_key?(key)
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

    # Returns an independent copy of this table.
    #
    # The copy holds the same entries and the same byte estimate. It uses a
    # fixed random seed, so its structure is deterministic. The copy never
    # changes after creation, which makes it safe to share across fibers.
    def dup : MemTable
      copy = MemTable.new(Random.new(0))
      each_entry do |entry|
        if entry.alive
          copy.put(entry.key, entry.value, entry.seq)
        else
          copy.delete(entry.key, entry.seq)
        end
      end
      copy
    end

    # Returns the node for the first key >= `start_key`. Used by iterators.
    def lower_bound(start_key : String) : SkipList::Node?
      @table.lower_bound(start_key)
    end
  end
end
