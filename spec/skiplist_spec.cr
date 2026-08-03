require "./spec_helper"

describe Cinderstore::SkipList do
  it "starts empty" do
    list = Cinderstore::SkipList.new
    list.empty?.should be_true
    list.size.should eq(0)
  end

  it "inserts and finds keys" do
    list = Cinderstore::SkipList.new
    list.insert("b", 2_i64, true, "two")
    list.insert("a", 1_i64, true, "one")
    list.insert("c", 3_i64, true, "three")
    list.size.should eq(3)
    list.get("a").not_nil!.value.should eq("one")
    list.get("b").not_nil!.value.should eq("two")
    list.get("c").not_nil!.value.should eq("three")
    list.get("z").should be_nil
  end

  it "overwrites the newest entry for a key" do
    list = Cinderstore::SkipList.new
    list.insert("k", 1_i64, true, "old")
    list.insert("k", 2_i64, true, "new")
    list.size.should eq(1)
    node = list.get("k").not_nil!
    node.value.should eq("new")
    node.seq.should eq(2_i64)
  end

  it "lower_bound finds the first key at or above a start" do
    list = Cinderstore::SkipList.new
    %w[apple banana cherry date].each_with_index do |key, i|
      list.insert(key, i.to_i64, true, key)
    end
    list.lower_bound("banana").not_nil!.key.should eq("banana")
    list.lower_bound("blueberry").not_nil!.key.should eq("cherry")
    list.lower_bound("").not_nil!.key.should eq("apple")
    list.lower_bound("zzz").should be_nil
  end

  it "iterates in sorted order through level zero" do
    list = Cinderstore::SkipList.new
    keys = %w[d a c e b]
    keys.each_with_index { |k, i| list.insert(k, i.to_i64, true, k) }
    node = list.lower_bound("")
    seen = [] of String
    while node
      seen << node.key
      node = node.forward[0]
    end
    seen.should eq(%w[a b c d e])
  end

  it "handles a large deterministic insert workload" do
    list = Cinderstore::SkipList.new
    5_000.times do |i|
      list.insert("key-%05d" % i, i.to_i64, true, "v#{i}")
    end
    list.size.should eq(5_000)
    list.get("key-02500").not_nil!.value.should eq("v2500")
  end
end
