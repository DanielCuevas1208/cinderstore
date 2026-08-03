module Cinderstore
  # A classic bloom filter over a set of keys.
  #
  # A bloom filter never reports a false negative. It may report false
  # positives. We store one bloom filter per sorted table. The reader
  # skips a table entirely when the filter says the key is absent.
  class BloomFilter
    # Returns the bit count and hash count for a target false positive rate.
    def self.optimal_params(count : Int, fpp : Float64) : Tuple(Int32, Int32)
      m = (-(count.to_f64 * Math.log(fpp)) / (Math.log(2.0) ** 2)).ceil.to_i
      m = 1 if m < 1
      m = ((m + 7) // 8) * 8
      k = ((m.to_f64 / count.to_f64) * Math.log(2.0)).round.to_i
      k = 1 if k < 1
      {m, k}
    end

    @bits : Bytes
    @m : Int32
    @k : Int32
    @count : Int32

    def initialize(@m : Int32, @k : Int32)
      @bits = Bytes.new((@m + 7) // 8, 0_u8)
      @count = 0
    end

    def m : Int32
      @m
    end

    def k : Int32
      @k
    end

    def count : Int32
      @count
    end

    # Builds a filter for a known key set.
    def self.build(keys : Array(String), fpp : Float64 = 0.01) : BloomFilter
      m, k = optimal_params(keys.size, fpp)
      filter = new(m, k)
      keys.each { |key| filter.insert(key) }
      filter
    end

    def insert(key : String) : Nil
      h1, h2 = hashes(key)
      @k.times do |i|
        index = (h1 &+ (i.to_u64 &* h2)) % @m.to_u64
        @bits[index // 8] |= (1_u8 << (index % 8))
      end
      @count += 1
    end

    def includes?(key : String) : Bool
      h1, h2 = hashes(key)
      @k.times do |i|
        index = (h1 &+ (i.to_u64 &* h2)) % @m.to_u64
        return false if (@bits[index // 8] & (1_u8 << (index % 8))) == 0
      end
      true
    end

    def serialize(io : IO) : Nil
      Util.write_varint(io, @m.to_u64)
      Util.write_varint(io, @k.to_u64)
      io.write(@bits)
    end

    def self.deserialize(io : IO) : BloomFilter
      m = Util.read_varint(io).to_i
      k = Util.read_varint(io).to_i
      filter = new(m, k)
      io.read_fully(filter.@bits)
      filter
    end

    private def hashes(key : String) : Tuple(UInt64, UInt64)
      data = key.to_slice
      {
        Util.fnv1a_64(data, 0x9e3779b97f4a7c15_u64),
        Util.fnv1a_64(data, 0xbf58476d1ce4e5b9_u64),
      }
    end
  end
end
