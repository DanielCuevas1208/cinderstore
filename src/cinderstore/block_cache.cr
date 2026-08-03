module Cinderstore
  # A bounded LRU cache for decoded table blocks.
  #
  # The cache stores the raw bytes of a block. Each entry is keyed by the
  # table id and the block index. Reads that miss on the bloom filter never
  # touch the cache. The cache is not thread safe; callers must hold the
  # database lock.
  class BlockCache
    # Doubly linked list node holding one cached block.
    class Node
      getter key : String
      property value : Bytes
      property prev : Node?
      property next_node : Node?

      def initialize(@key : String, @value : Bytes)
      end
    end

    @capacity : Int32
    @map : Hash(String, Node)
    @head : Node
    @tail : Node
    @size : Int32
    @hits : Int64 = 0_i64
    @misses : Int64 = 0_i64

    def initialize(@capacity : Int32)
      @map = Hash(String, Node).new
      @head = Node.new("", Bytes.new(0))
      @tail = Node.new("", Bytes.new(0))
      @head.next_node = @tail
      @tail.prev = @head
      @size = 0
    end

    def capacity : Int32
      @capacity
    end

    def hits : Int64
      @hits
    end

    def misses : Int64
      @misses
    end

    # Returns the cached value for `key`, or loads it with `block`.
    def fetch(key : String, &block : -> Bytes) : Bytes
      if node = @map[key]?
        @hits += 1
        move_to_front(node)
        return node.value
      end
      @misses += 1
      value = block.call
      put(key, value)
      value
    end

    def clear : Nil
      @map.clear
      @head.next_node = @tail
      @tail.prev = @head
      @size = 0
    end

    private def put(key : String, value : Bytes) : Nil
      node = Node.new(key, value)
      @map[key] = node
      link_front(node)
      @size += 1
      while @size > @capacity
        evict
      end
    end

    private def move_to_front(node : Node) : Nil
      unlink(node)
      link_front(node)
    end

    private def unlink(node : Node) : Nil
      node.prev.not_nil!.next_node = node.next_node
      node.next_node.not_nil!.prev = node.prev
    end

    private def link_front(node : Node) : Nil
      node.next_node = @head.next_node
      node.prev = @head
      @head.next_node.not_nil!.prev = node
      @head.next_node = node
    end

    private def evict : Nil
      victim = @tail.prev
      return unless victim && victim != @head
      unlink(victim)
      @map.delete(victim.key)
      @size -= 1
    end
  end
end
