require "./spec_helper"

describe Cinderstore::MemTable do
  it "gets and puts values" do
    mem = Cinderstore::MemTable.new
    mem.put("a", "1", 1_i64)
    mem.put("b", "2", 2_i64)
    mem.get("a").should eq("1")
    mem.get("b").should eq("2")
    mem.get("c").should be_nil
    mem.size.should eq(2)
  end

  it "overwrites values and keeps the newest sequence" do
    mem = Cinderstore::MemTable.new
    mem.put("k", "one", 1_i64)
    mem.put("k", "two", 2_i64)
    mem.get("k").should eq("two")
    mem.size.should eq(1)
    mem.get_entry("k").not_nil!.seq.should eq(2_i64)
  end

  it "hides a value behind a tombstone" do
    mem = Cinderstore::MemTable.new
    mem.put("k", "v", 1_i64)
    mem.delete("k", 2_i64)
    mem.get("k").should be_nil
    mem.get_entry("k").not_nil!.alive.should be_false
    mem.size.should eq(1)
  end

  it "resurrects a key after put, delete, put" do
    mem = Cinderstore::MemTable.new
    mem.put("k", "v1", 1_i64)
    mem.delete("k", 2_i64)
    mem.put("k", "v2", 3_i64)
    mem.get("k").should eq("v2")
    mem.get_entry("k").not_nil!.seq.should eq(3_i64)
  end

  it "tracks approximate bytes" do
    mem = Cinderstore::MemTable.new
    before = mem.approximate_bytes
    mem.put("abcdef", "123456", 1_i64)
    after = mem.approximate_bytes
    (after - before).should eq(12 + Cinderstore::MemTable::OVERHEAD)
  end

  it "iterates from a start key in order" do
    mem = Cinderstore::MemTable.new
    %w[apple banana cherry date].each_with_index { |k, i| mem.put(k, k, i.to_i64) }
    keys = [] of String
    mem.each_from("banana") { |e| keys << e.key }
    keys.should eq(%w[banana cherry date])
  end
end
