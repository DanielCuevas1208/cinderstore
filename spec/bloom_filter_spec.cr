require "./spec_helper"

describe Cinderstore::BloomFilter do
  it "never reports a false negative" do
    keys = 500.times.map { |i| "key-#{i}-#{i * 7}" }.to_a
    filter = Cinderstore::BloomFilter.build(keys, 0.01)
    keys.each { |key| filter.includes?(key).should be_true }
  end

  it "keeps false positives low" do
    keys = 1000.times.map { |i| "item-#{i}" }.to_a
    filter = Cinderstore::BloomFilter.build(keys, 0.01)
    missing = 0
    1_000.times do |i|
      candidate = "absent-#{i}"
      missing += 1 if filter.includes?(candidate)
    end
    missing.should be < 30
  end

  it "chooses sane parameters" do
    m, k = Cinderstore::BloomFilter.optimal_params(1_000, 0.01)
    k.should be > 0
    m.should be > 0
    m.should be >= 1_000
  end

  it "survives serialization" do
    keys = 100.times.map { |i| "k#{i}" }.to_a
    filter = Cinderstore::BloomFilter.build(keys, 0.01)
    io = IO::Memory.new
    filter.serialize(io)
    io.pos = 0
    copy = Cinderstore::BloomFilter.deserialize(io)
    keys.each { |key| copy.includes?(key).should be_true }
  end
end
