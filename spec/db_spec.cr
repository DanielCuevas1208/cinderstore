require "./spec_helper"

def wait_until(timeout : Time::Span = 5.seconds, &block : -> Bool) : Nil
  deadline = Time.instant + timeout
  until block.call
    raise "condition not met in time" if Time.instant >= deadline
    sleep 10.milliseconds
  end
end

describe Cinderstore::DB do
  it "stores and reads values" do
    Cinderstore::SpecHelpers.with_db("db-basic") do |db, _path|
      db.put("alpha", "one")
      db.put("beta", "two")
      db.get("alpha").should eq("one")
      db.get("beta").should eq("two")
      db.get("gamma").should be_nil
    end
  end

  it "overwrites existing values" do
    Cinderstore::SpecHelpers.with_db("db-overwrite") do |db, _path|
      db.put("k", "v1")
      db.put("k", "v2")
      db.get("k").should eq("v2")
      db.scan.size.should eq(1)
    end
  end

  it "deletes values" do
    Cinderstore::SpecHelpers.with_db("db-delete") do |db, _path|
      db.put("k", "v")
      db.delete("k")
      db.get("k").should be_nil
      db.scan.size.should eq(0)
    end
  end

  it "supports put after delete" do
    Cinderstore::SpecHelpers.with_db("db-resurrect") do |db, _path|
      db.put("k", "v1")
      db.delete("k")
      db.put("k", "v2")
      db.get("k").should eq("v2")
    end
  end

  it "scans a half-open range in key order" do
    Cinderstore::SpecHelpers.with_db("db-scan") do |db, _path|
      %w[apple banana cherry date].each { |k| db.put(k, k.upcase) }
      rows = db.scan("banana", "date")
      rows.map(&.[0]).should eq(%w[banana cherry])
      rows.first[1].should eq("BANANA")
    end
  end

  it "limits scan results" do
    Cinderstore::SpecHelpers.with_db("db-limit") do |db, _path|
      10.times { |i| db.put("k%02d" % i, "v") }
      db.scan("", nil, 3).size.should eq(3)
      db.scan("", nil, -1).size.should eq(10)
    end
  end

  it "flushes the memtable into a table" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("db-flush", config) do |db, _path|
      db.put("a", "1")
      db.put("b", "2")
      db.stats.tables.should eq(0)
      db.flush
      db.stats.tables.should eq(1)
      db.stats.l0.should eq(1)
      db.stats.entries.should eq(2)
      db.get("a").should eq("1")
      db.get("b").should eq("2")
    end
  end

  it "reads from tables and the memtable together" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("db-mixed", config) do |db, _path|
      db.put("a", "tabled")
      db.flush
      db.put("b", "memtable")
      db.get("a").should eq("tabled")
      db.get("b").should eq("memtable")
      db.scan.map(&.[0]).should eq(%w[a b])
    end
  end

  it "keeps a tombstone across a table boundary" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("db-tombstone", config) do |db, _path|
      db.put("k", "old")
      db.flush
      db.delete("k")
      db.flush
      db.stats.tables.should eq(2)
      db.get("k").should be_nil
      db.scan.size.should eq(0)
    end
  end

  it "recovers data after a restart" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("db-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("a", "1")
      db.put("b", "2")
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.get("a").should eq("1")
      reopened.get("b").should eq("2")
      reopened.close
    end
  end

  it "recovers after a restart without a manifest" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("db-nomanifest") do |path|
      db = Cinderstore::DB.new(path, config)
      5.times { |i| db.put("k#{i}", "v#{i}") }
      db.close

      File.delete(File.join(path, "MANIFEST"))

      reopened = Cinderstore::DB.new(path, config)
      5.times { |i| reopened.get("k#{i}").should eq("v#{i}") }
      reopened.close
    end
  end

  it "recovers the intact prefix of a torn write ahead log" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("db-torn") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("alpha", "1")
      db.put("beta", "2")
      db.put("gamma", "3")
      db.close

      wal = Dir.children(path).find { |n| n.ends_with?(".wal") }.not_nil!
      Cinderstore::SpecHelpers.truncate(File.join(path, wal), File.size(File.join(path, wal)) - 3)

      reopened = Cinderstore::DB.new(path, config)
      reopened.get("alpha").should eq("1")
      reopened.get("beta").should eq("2")
      reopened.get("gamma").should be_nil
      reopened.close
    end
  end

  it "auto flushes when the memtable limit is reached" do
    config = Cinderstore::SpecHelpers.small_config(memtable_limit: 2_000)
    Cinderstore::SpecHelpers.with_db("db-autoflush", config) do |db, _path|
      60.times { |i| db.put("k%03d" % i, "value-" + "x" * 40) }
      wait_until { db.stats.tables >= 1 }
      db.get("k000").should eq("value-" + "x" * 40)
    end
  end

  it "serves repeated reads from the block cache" do
    config = Cinderstore::SpecHelpers.small_config(block_size: 128, memtable_limit: 4_096)
    Cinderstore::SpecHelpers.with_db("db-cache", config) do |db, _path|
      200.times { |i| db.put("k%03d" % i, "value-#{i}") }
      db.flush
      hits_before = db.stats.cache_hits
      50.times { |i| db.get("k%03d" % (i * 3)).should eq("value-#{i * 3}") }
      db.stats.cache_hits.should be > hits_before
    end
  end

  it "returns rich stats" do
    Cinderstore::SpecHelpers.with_db("db-stats") do |db, _path|
      db.put("a", "1")
      stats = db.stats
      stats.entries.should eq(1)
      stats.seq.should eq(1)
      stats.to_json.should contain("tables")
    end
  end

  it "rejects empty keys" do
    Cinderstore::SpecHelpers.with_db("db-invalid") do |db, _path|
      expect_raises(Cinderstore::InvalidKeyError) { db.put("", "v") }
      expect_raises(Cinderstore::InvalidKeyError) { db.get("") }
    end
  end

  it "rejects oversized keys" do
    Cinderstore::SpecHelpers.with_db("db-invalid") do |db, _path|
      key = "x" * (Cinderstore::DB::MAX_KEY_BYTES + 1)
      expect_raises(Cinderstore::InvalidKeyError) { db.put(key, "v") }
    end
  end

  it "raises on reads after close" do
    Cinderstore::SpecHelpers.with_db("db-closed") do |db, _path|
      db.close
      expect_raises(Cinderstore::ClosedError) { db.get("a") }
      expect_raises(Cinderstore::ClosedError) { db.put("a", "b") }
    end
  end
end
