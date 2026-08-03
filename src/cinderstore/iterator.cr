module Cinderstore
  module Store
    # Streams entries in ascending key order.
    #
    # Iterators expose a keyed seek. They do not own their underlying
    # resources; the database owns table readers.
    abstract class Iter
      # Repositions the iterator at the first entry with key >= `key`.
      abstract def seek(key : String)

      # Returns the next entry, or nil at the end of the stream.
      abstract def next? : Entry?

      # Releases per-iterator resources. A no-op for borrowed readers.
      def close : Nil
      end
    end
  end

  # Iterates over a memtable, starting at a key offset.
  class MemIter < Store::Iter
    def initialize(@mem : MemTable, start : String = "")
      @node = @mem.lower_bound(start)
    end

    def seek(key : String) : Nil
      @node = @mem.lower_bound(key)
    end

    def next? : Entry?
      node = @node
      return nil unless node
      @node = node.forward[0]
      Entry.new(node.key, node.seq, node.alive, node.value)
    end
  end

  # Iterates over one sorted table using its block index.
  class TableIter < Store::Iter
    def initialize(@reader : SstableReader, start : String = "")
      @block_idx = 0
      @entries = [] of Entry
      @pos = 0
      @done = false
      seek(start) unless start.empty?
    end

    def seek(key : String) : Nil
      @block_idx = @reader.find_block_for(key)
      @done = false
      @entries = [] of Entry
      @pos = 0
      load_next_block
      skip_less_than(key)
    end

    def next? : Entry?
      return nil if @done
      if @pos >= @entries.size
        load_next_block
        return nil if @done
      end
      entry = @entries[@pos]
      @pos += 1
      entry
    end

    private def load_next_block : Nil
      if @block_idx >= @reader.block_count
        @done = true
        @entries = [] of Entry
        @pos = 0
      else
        @entries = @reader.load_block_entries(@block_idx)
        @block_idx += 1
        @pos = 0
      end
    end

    private def skip_less_than(key : String) : Nil
      loop do
        break if @done
        if @pos >= @entries.size
          load_next_block
          next
        end
        break if @entries[@pos].key >= key
        @pos += 1
      end
    end
  end

  # Merges several sorted iterators into one sorted stream.
  #
  # The merge treats newer entries as larger. It yields exactly one entry
  # per key: the entry with the highest sequence number. This is what makes
  # tombstone removal and deduplication possible during compaction.
  class MergeIter(I) < Store::Iter
    private record HeapItem, key : String, seq : Int64, value : String, alive : Bool, source : Int32

    @sources : Array(I)
    @heap : Array(HeapItem)

    def initialize(@sources : Array(I))
      @heap = [] of HeapItem
      @sources.each_with_index do |src, i|
        if entry = src.next?
          @heap << HeapItem.new(entry.key, entry.seq, entry.value, entry.alive, i)
        end
      end
      heapify
    end

    def seek(key : String) : Nil
      @heap.clear
      @sources.each_with_index do |src, i|
        src.seek(key)
        if entry = src.next?
          @heap << HeapItem.new(entry.key, entry.seq, entry.value, entry.alive, i)
        end
      end
      heapify
    end

    def next? : Entry?
      item = pop_min
      return nil unless item

      if entry = @sources[item.source].next?
        @heap << HeapItem.new(entry.key, entry.seq, entry.value, entry.alive, item.source)
        sift_up(@heap.size - 1)
      end

      # Discard older duplicates for the same key.
      while !@heap.empty? && @heap[0].key == item.key
        dup = pop_min.not_nil!
        if entry = @sources[dup.source].next?
          @heap << HeapItem.new(entry.key, entry.seq, entry.value, entry.alive, dup.source)
          sift_up(@heap.size - 1)
        end
      end

      Entry.new(item.key, item.seq, item.alive, item.value)
    end

    # A key orders before another key. Ties order by newer sequence first.
    private def less?(a : HeapItem, b : HeapItem) : Bool
      if a.key == b.key
        a.seq > b.seq
      else
        a.key < b.key
      end
    end

    private def heapify : Nil
      i = @heap.size // 2 - 1
      while i >= 0
        sift_down(i)
        i -= 1
      end
    end

    private def sift_up(idx : Int32) : Nil
      i = idx
      while i > 0
        parent = (i - 1) // 2
        break if less?(@heap[parent], @heap[i])
        swap(i, parent)
        i = parent
      end
    end

    private def sift_down(idx : Int32) : Nil
      i = idx
      loop do
        left = 2 * i + 1
        right = left + 1
        smallest = i
        smallest = left if left < @heap.size && less?(@heap[left], @heap[smallest])
        smallest = right if right < @heap.size && less?(@heap[right], @heap[smallest])
        break if smallest == i
        swap(i, smallest)
        i = smallest
      end
    end

    private def pop_min : HeapItem?
      return nil if @heap.empty?
      top = @heap[0]
      last = @heap.pop
      unless @heap.empty?
        @heap[0] = last
        sift_down(0)
      end
      top
    end

    private def swap(a : Int32, b : Int32) : Nil
      tmp = @heap[a]
      @heap[a] = @heap[b]
      @heap[b] = tmp
    end
  end

  # Wraps an iterator and hides tombstone entries.
  class LiveIter < Store::Iter
    def initialize(@inner : Store::Iter)
    end

    def seek(key : String) : Nil
      @inner.seek(key)
    end

    def next? : Entry?
      while entry = @inner.next?
        return entry if entry.alive
      end
      nil
    end

    def close : Nil
      @inner.close
    end
  end
end
