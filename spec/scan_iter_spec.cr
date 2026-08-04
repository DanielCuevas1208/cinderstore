require "./spec_helper"

describe Cinderstore::DB do
  it "streams live pairs in a half-open primary-key range" do
    Cinderstore::SpecHelpers.with_db("scan-iter") do |db, _path|
      %w[apple banana cherry date].each { |key| db.put(key, key.upcase) }

      iter = db.scan_iter("banana", "date")
      iter.next?.should eq({"banana", "BANANA"})
      iter.next?.should eq({"cherry", "CHERRY"})
      iter.next?.should be_nil
      iter.close
    end
  end

  it "keeps a database iterator at its creation snapshot" do
    Cinderstore::SpecHelpers.with_db("scan-iter-snapshot") do |db, _path|
      db.put("a", "1")
      db.put("b", "2")
      iter = db.scan_iter
      db.put("c", "3")
      db.delete("b")

      iter.to_a.should eq([{"a", "1"}, {"b", "2"}])
      iter.close
      expect_raises(Cinderstore::SnapshotReleasedError) { iter.next? }
    end
  end

  it "keeps a caller snapshot alive when its iterator closes" do
    Cinderstore::SpecHelpers.with_db("scan-iter-caller-snapshot") do |db, _path|
      db.put("a", "1")
      db.put("b", "2")
      snapshot = db.snapshot
      iter = snapshot.scan_iter("a")
      keys = [] of String
      iter.each { |key, _value| keys << key }
      iter.close

      keys.should eq(%w[a b])
      snapshot.get("a").should eq("1")
      snapshot.release
    end
  end

  it "streams across tables and skips tombstones" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("scan-iter-tables", config) do |db, _path|
      db.put("a", "one")
      db.put("b", "two")
      db.flush
      db.delete("b")
      db.put("c", "three")
      db.flush

      iter = db.scan_iter
      iter.to_a.should eq([{"a", "one"}, {"c", "three"}])
      iter.close
    end
  end
end
