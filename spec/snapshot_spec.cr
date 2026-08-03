require "./spec_helper"

describe Cinderstore::DB::Snapshot do
  it "captures the state at creation" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("snapshot-basic", config) do |db, _path|
      db.put("a", "1")
      db.put("b", "2")
      view = db.snapshot
      db.put("c", "3")
      db.delete("a")

      view.get("a").should eq("1")
      view.get("b").should eq("2")
      view.get("c").should be_nil
      view.scan.map(&.[0]).should eq(%w[a b])

      db.get("a").should be_nil
      db.get("c").should eq("3")
      view.close
    end
  end

  it "reports the captured sequence number" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("snapshot-seq", config) do |db, _path|
      db.put("a", "1")
      db.put("b", "2")
      view = db.snapshot
      view.seq.should eq(2)
      db.put("c", "3")
      view.seq.should eq(2)
      view.close
    end
  end

  it "matches the live store when nothing changes" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("snapshot-match", config) do |db, _path|
      %w[alpha beta gamma].each_with_index { |key, i| db.put(key, i.to_s) }
      view = db.snapshot
      view.scan.should eq(db.scan)
      view.get("beta").should eq(db.get("beta"))
      view.close
    end
  end

  it "scans a range and respects the limit" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("snapshot-range", config) do |db, _path|
      10.times { |i| db.put("k%02d" % i, "v") }
      view = db.snapshot
      view.scan("k02", "k06").map(&.[0]).should eq(%w[k02 k03 k04 k05])
      view.scan("", nil, 3).size.should eq(3)
      view.close
    end
  end

  it "iterates with a block" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("snapshot-each", config) do |db, _path|
      %w[a b c d].each { |key| db.put(key, key.upcase) }
      view = db.snapshot
      keys = [] of String
      view.each("b", "d") { |key, _value| keys << key }
      keys.should eq(%w[b c])
      view.close
    end
  end

  it "ignores later flushes and compactions" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("snapshot-flush-compact", config) do |db, _path|
      100.times { |i| db.put("k%03d" % i, "old#{i}") }
      db.flush
      view = db.snapshot

      db.put("k000", "new")
      db.delete("k001")
      db.flush
      db.compact

      view.scan.size.should eq(100)
      view.get("k000").should eq("old0")
      view.get("k001").should eq("old1")

      db.scan.size.should eq(99)
      db.get("k000").should eq("new")
      db.get("k001").should be_nil
      view.close
    end
  end

  it "defers table deletion while a snapshot is open" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("snapshot-pin", config) do |db, path|
      200.times { |i| db.put("k%03d" % i, "v#{i}") }
      db.flush
      db.put("k500", "v")
      db.flush
      db.stats.tables.should eq(2)

      view = db.snapshot
      db.compact
      db.stats.tables.should eq(1)

      on_disk = Dir.children(path).count { |name| name.ends_with?(".sst") }
      on_disk.should be > db.stats.tables

      view.get("k123").should eq("v123")
      view.scan.size.should eq(201)

      view.close
      remaining = Dir.children(path).count { |name| name.ends_with?(".sst") }
      remaining.should eq(db.stats.tables)
    end
  end

  it "keeps snapshots independent of each other" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("snapshot-independent", config) do |db, _path|
      db.put("a", "1")
      first = db.snapshot
      db.put("b", "2")
      second = db.snapshot
      db.put("c", "3")

      first.scan.map(&.[0]).should eq(%w[a])
      second.scan.map(&.[0]).should eq(%w[a b])

      second.close
      first.get("a").should eq("1")
      first.scan.map(&.[0]).should eq(%w[a])
      first.close
    end
  end

  it "remains readable after the database closes" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("snapshot-after-close") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("a", "1")
      view = db.snapshot
      db.close

      view.get("a").should eq("1")
      view.scan.map(&.[0]).should eq(%w[a])
      view.close
    end
  end

  it "raises on reads after close" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("snapshot-closed", config) do |db, _path|
      db.put("a", "1")
      view = db.snapshot
      view.close
      expect_raises(Cinderstore::ClosedError) { view.get("a") }
      expect_raises(Cinderstore::ClosedError) { view.scan }
    end
  end

  it "rejects empty keys" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("snapshot-invalid", config) do |db, _path|
      view = db.snapshot
      expect_raises(Cinderstore::InvalidKeyError) { view.get("") }
      view.close
    end
  end
end
