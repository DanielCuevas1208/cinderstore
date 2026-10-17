require "./spec_helper"

describe Cinderstore::DB do
  it "bounds primary iterators and handles zero limits" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("limit-primary", config) do |db, _path|
      %w[a b c].each { |key| db.put(key, key.upcase) }

      iter = db.scan_iter("", nil, 2)
      iter.to_a.map(&.[0]).should eq(%w[a b])
      iter.close

      closed_iter = db.scan_iter("", nil, 1)
      closed_iter.next?.should eq({"a", "A"})
      closed_iter.close
      expect_raises(Cinderstore::SnapshotReleasedError) { closed_iter.next? }

      prefix_iter = db.scan_prefix_iter("", 1)
      prefix_iter.to_a.map(&.[0]).should eq(%w[a])
      prefix_iter.close

      db.scan("", nil, 0).should eq([] of Tuple(String, String))
      db.scan_prefix("", 0).should eq([] of Tuple(String, String))
    end
  end

  it "applies bounds to snapshot primary iterators" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("limit-snapshot", config) do |db, _path|
      %w[item-a item-b item-c].each { |key| db.put(key, key) }
      snapshot = db.snapshot

      range_iter = snapshot.scan_iter("item-a", nil, 2)
      range_iter.to_a.map(&.[0]).should eq(%w[item-a item-b])
      range_iter.close

      prefix_iter = snapshot.scan_prefix_iter("item-", 1)
      prefix_iter.to_a.map(&.[0]).should eq(%w[item-a])
      prefix_iter.close

      snapshot.scan("", nil, 0).should eq([] of Tuple(String, String))
      snapshot.release
    end
  end

  it "bounds index iterators and materialized queries" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("limit-index", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      4.times { |index| db.put("key-#{index}", "same") }

      db.query("by-value", "same", 0).should eq([] of String)
      db.query_range("by-value", "same", "samez", 0).should eq([] of String)

      exact_iter = db.query_iter("by-value", "same", 2)
      exact_iter.to_a.should eq(%w[key-0 key-1])
      exact_iter.close

      range_iter = db.query_range_iter("by-value", "same", "samez", 2)
      range_iter.to_a.should eq(%w[key-0 key-1])
      range_iter.close

      snapshot = db.snapshot
      snapshot.query_iter("by-value", "same", 2).to_a.should eq(%w[key-0 key-1])
      snapshot.query_range_iter("by-value", "same", "samez", 2).to_a.should eq(%w[key-0 key-1])
      snapshot.release

      db.delete("key-0")
      remaining = db.query_iter("by-value", "same", 2)
      remaining.to_a.should eq(%w[key-1 key-2])
      remaining.close
    end
  end
end
