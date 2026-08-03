require "./spec_helper"

describe Cinderstore::Snapshot do
  it "sees the state at creation, not later writes" do
    Cinderstore::SpecHelpers.with_db("snap-afterwrite") do |db, _path|
      db.put("a", "1")
      snap = db.snapshot
      db.put("b", "2")
      db.delete("a")
      snap.get("a").should eq("1")
      snap.get("b").should be_nil
      snap.scan.map(&.[0]).should eq(%w[a])
      snap.count.should eq(1_i64)
      db.get("a").should be_nil
      db.get("b").should eq("2")
    end
  end

  it "sees deletes that happened before creation" do
    Cinderstore::SpecHelpers.with_db("snap-beforedelete") do |db, _path|
      db.put("a", "1")
      db.delete("a")
      snap = db.snapshot
      snap.get("a").should be_nil
      snap.count.should eq(0_i64)
    end
  end

  it "survives a flush of new writes" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("snap-flush", config) do |db, _path|
      db.put("a", "old")
      snap = db.snapshot
      db.put("b", "new")
      db.flush
      snap.get("a").should eq("old")
      snap.get("b").should be_nil
      snap.scan.map(&.[0]).should eq(%w[a])
      db.scan.map(&.[0]).should eq(%w[a b])
    end
  end

  it "reads keys that live in tables" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("snap-tables", config) do |db, _path|
      db.put("alpha", "1")
      db.put("beta", "2")
      db.flush
      db.put("gamma", "3")
      db.flush
      snap = db.snapshot
      snap.get("alpha").should eq("1")
      snap.get("beta").should eq("2")
      snap.get("gamma").should eq("3")
      snap.get("delta").should be_nil
      snap.scan.map(&.[0]).should eq(%w[alpha beta gamma])
    end
  end

  it "keeps table files alive while a snapshot holds them" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("snap-files") do |path|
      db = Cinderstore::DB.new(path, config)
      begin
        db.put("a", "1")
        db.flush
        db.put("b", "2")
        db.flush
        sst_count = -> { Dir.children(path).count { |n| n.ends_with?(".sst") } }
        sst_count.call.should eq(2)

        snap = db.snapshot
        db.compact
        # Compaction added one table. The two old files survive because the
        # snapshot still references them.
        sst_count.call.should eq(3)
        snap.get("a").should eq("1")
        snap.get("b").should eq("2")

        snap.release
        # The orphaned files are gone now.
        sst_count.call.should eq(1)
        db.get("a").should eq("1")
        db.get("b").should eq("2")
      ensure
        db.close rescue nil
      end
    end
  end

  it "keeps two snapshots independent" do
    Cinderstore::SpecHelpers.with_db("snap-two") do |db, _path|
      db.put("a", "1")
      first = db.snapshot
      db.put("b", "2")
      second = db.snapshot
      db.put("c", "3")
      first.scan.map(&.[0]).should eq(%w[a])
      second.scan.map(&.[0]).should eq(%w[a b])
      db.scan.map(&.[0]).should eq(%w[a b c])
      first.release
      second.release
    end
  end

  it "iterates a consistent range" do
    Cinderstore::SpecHelpers.with_db("snap-iter") do |db, _path|
      5.times { |i| db.put("k#{i}", "v#{i}") }
      snap = db.snapshot
      db.put("k5", "v5")
      rows = [] of String
      iter = snap.iter("k2")
      while entry = iter.next?
        rows << entry.key
      end
      rows.should eq(%w[k2 k3 k4])
    end
  end

  it "iterates a snapshot that spans tables" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("snap-tableiter", config) do |db, _path|
      5.times { |i| db.put("k#{i}", "v#{i}") }
      db.flush
      db.put("k5", "v5")
      db.put("k6", "v6")
      db.flush
      snap = db.snapshot
      db.put("k7", "v7")
      rows = [] of String
      iter = snap.iter("k4")
      while entry = iter.next?
        rows << entry.key
      end
      rows.should eq(%w[k4 k5 k6])
    end
  end

  it "scans a bounded range" do
    Cinderstore::SpecHelpers.with_db("snap-scan") do |db, _path|
      %w[a b c d e].each { |k| db.put(k, k.upcase) }
      snap = db.snapshot
      snap.scan("b", "e").map(&.[0]).should eq(%w[b c d])
      snap.scan("", nil, 2).map(&.[0]).should eq(%w[a b])
    end
  end

  it "yields rows with each" do
    Cinderstore::SpecHelpers.with_db("snap-each") do |db, _path|
      db.put("a", "1")
      db.put("b", "2")
      snap = db.snapshot
      keys = [] of String
      snap.each("b") { |key, _value| keys << key }
      keys.should eq(%w[b])
    end
  end

  it "reports a stable count" do
    Cinderstore::SpecHelpers.with_db("snap-count") do |db, _path|
      db.put("a", "1")
      db.put("b", "2")
      snap = db.snapshot
      snap.count.should eq(2_i64)
      db.put("c", "3")
      snap.count.should eq(2_i64)
    end
  end

  it "releases the snapshot after a block" do
    Cinderstore::SpecHelpers.with_db("snap-block") do |db, _path|
      db.put("a", "1")
      value = nil
      db.snapshot do |snap|
        value = snap.get("a")
        snap.released?.should be_false
      end
      value.should eq("1")
    end
  end

  it "raises when used after release" do
    Cinderstore::SpecHelpers.with_db("snap-released") do |db, _path|
      db.put("a", "1")
      snap = db.snapshot
      snap.release
      snap.release
      snap.close
      expect_raises(Cinderstore::SnapshotReleasedError) { snap.get("a") }
      expect_raises(Cinderstore::SnapshotReleasedError) { snap.scan }
      expect_raises(Cinderstore::SnapshotReleasedError) { snap.iter }
    end
  end

  it "stops an iterator after the snapshot is released" do
    Cinderstore::SpecHelpers.with_db("snap-iterreleased") do |db, _path|
      db.put("a", "1")
      snap = db.snapshot
      iter = snap.iter
      snap.release
      expect_raises(Cinderstore::SnapshotReleasedError) { iter.next? }
    end
  end
end
