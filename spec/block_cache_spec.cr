require "./spec_helper"

describe Cinderstore::BlockCache do
  it "returns the loaded value and counts a miss" do
    cache = Cinderstore::BlockCache.new(4)
    value = cache.fetch("a") { "hello".to_slice }
    String.new(value).should eq("hello")
    cache.misses.should eq(1)
    cache.hits.should eq(0)
  end

  it "serves repeated fetches from the cache" do
    cache = Cinderstore::BlockCache.new(4)
    loads = 0
    3.times do
      cache.fetch("k") { loads += 1; "x".to_slice }
    end
    loads.should eq(1)
    cache.hits.should eq(2)
    cache.misses.should eq(1)
  end

  it "evicts the least recently used entry" do
    cache = Cinderstore::BlockCache.new(2)
    cache.fetch("a") { "a".to_slice }
    cache.fetch("b") { "b".to_slice }
    cache.fetch("a") { "a2".to_slice }
    cache.fetch("c") { "c".to_slice }

    # "b" was the least recently used, so it must be gone.
    loads = 0
    cache.fetch("b") { loads += 1; "b2".to_slice }
    loads.should eq(1)
  end

  it "respects a zero capacity" do
    cache = Cinderstore::BlockCache.new(0)
    loads = 0
    cache.fetch("k") { loads += 1; "x".to_slice }
    cache.fetch("k") { loads += 1; "x".to_slice }
    loads.should eq(2)
  end

  it "clears all entries" do
    cache = Cinderstore::BlockCache.new(4)
    cache.fetch("a") { "a".to_slice }
    cache.clear
    loads = 0
    cache.fetch("a") { loads += 1; "a".to_slice }
    loads.should eq(1)
  end
end
