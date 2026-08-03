module Cinderstore
  # A probabilistic skip list that keeps keys in ascending order.
  #
  # Each node holds the newest entry for its key. Insertions are O(log n)
  # on average. Forward pointers at level zero form a sorted linked list,
  # which gives us cheap in-order scans for range queries and flushes.
  class SkipList
    MAX_LEVEL =   32
    PROMOTION = 0.25

    # A node in the skip list.
    class Node
      getter key : String
      property seq : Int64
      property alive : Bool
      property value : String
      property forward : Array(Node?)

      def initialize(@key : String, @seq : Int64, @alive : Bool, @value : String, level : Int32)
        @forward = Array(Node?).new(level, nil)
      end
    end

    @head : Node
    @level : Int32 = 1
    @count : Int64 = 0_i64
    @rng : Random

    def initialize(rng : Random = Random.new)
      @head = Node.new("", 0_i64, false, "", MAX_LEVEL)
      @rng = rng
    end

    def empty? : Bool
      @count == 0
    end

    def size : Int64
      @count
    end

    # Inserts the newest entry for `key`. Replaces any existing entry.
    def insert(key : String, seq : Int64, alive : Bool, value : String) : Nil
      update = Array(Node).new(MAX_LEVEL) { @head }
      current = @head

      (@level - 1).downto(0) do |i|
        loop do
          nxt = current.forward[i]
          break unless nxt
          break if nxt.key >= key
          current = nxt
        end
        update[i] = current
      end

      nxt = current.forward[0]
      if nxt && nxt.key == key
        nxt.seq = seq
        nxt.alive = alive
        nxt.value = value
        return
      end

      level = random_level
      if level > @level
        (level - 1).downto(@level) { |i| update[i] = @head }
        @level = level
      end

      node = Node.new(key, seq, alive, value, level)
      (0...level).each do |i|
        node.forward[i] = update[i].forward[i]
        update[i].forward[i] = node
      end
      @count += 1
    end

    # Returns the node for `key`, or nil when the key is absent.
    def get(key : String) : Node?
      current = @head
      (@level - 1).downto(0) do |i|
        loop do
          nxt = current.forward[i]
          break unless nxt
          break if nxt.key >= key
          current = nxt
        end
      end
      node = current.forward[0]
      return node if node && node.key == key
      nil
    end

    # Returns the first node whose key is greater than or equal to `start`.
    def lower_bound(start : String) : Node?
      current = @head
      (@level - 1).downto(0) do |i|
        loop do
          nxt = current.forward[i]
          break unless nxt
          break if nxt.key >= start
          current = nxt
        end
      end
      current.forward[0]
    end

    private def random_level : Int32
      level = 1
      while level < MAX_LEVEL && @rng.rand < PROMOTION
        level += 1
      end
      level
    end
  end
end
