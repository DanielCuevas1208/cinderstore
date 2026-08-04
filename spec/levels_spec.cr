require "./spec_helper"

# A config with a tiny level-one target so tests can grow levels fast.
private def tiny_level_config(level_target_bytes : Int64 = 4_096)
  config = Cinderstore::SpecHelpers.fast_config
  config.level_target_bytes = level_target_bytes
  config
end

# Writes `count` keys with enough bytes to exceed a 4 KB level target.
private def put_batch(db : Cinderstore::DB, prefix : String, count : Int32) : Nil
  count.times do |i|
    db.put("#{prefix}-%03d" % i, "v#{i}-" + "x" * 40)
  end
end

describe "Cinderstore leveled compaction" do
  it "moves a lone flushed table down one level" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("levels-move", config) do |db, _path|
      db.put("a", "1")
      db.put("b", "2")
      db.flush
      db.stats.levels.should eq([1])
      db.compact
      db.stats.levels.should eq([0, 1])
      db.get("a").should eq("1")
      db.get("b").should eq("2")
    end
  end

  it "keeps tables in a level disjoint" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("levels-disjoint", config) do |db, _path|
      db.put("a", "1")
      db.put("m", "2")
      db.flush
      db.compact
      db.put("n", "3")
      db.put("z", "4")
      db.flush
      db.compact
      db.stats.levels.should eq([0, 2])
      db.scan.map(&.[0]).should eq(%w[a m n z])
    end
  end

  it "preserves level-one tables that do not overlap a compact" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("levels-preserve", config) do |db, _path|
      db.put("a", "1")
      db.put("m", "2")
      db.flush
      db.compact
      db.put("n", "3")
      db.put("z", "4")
      db.flush
      db.compact
      db.put("a", "updated")
      db.flush
      db.compact
      db.stats.levels.should eq([0, 2])
      db.get("a").should eq("updated")
      db.scan.map(&.[1]).should eq(%w[updated 2 3 4])
    end
  end

  it "compacts an overflowing level one into level two" do
    config = tiny_level_config
    Cinderstore::SpecHelpers.with_db("levels-grow", config) do |db, _path|
      put_batch(db, "key", 120)
      db.flush
      db.compact
      db.stats.levels.should eq([0, 1])
      db.compact
      db.stats.levels.should eq([0, 0, 1])
      db.get("key-040").should eq("v40-" + "x" * 40)
    end
  end

  it "keeps a tombstone while older data lives below" do
    config = tiny_level_config
    Cinderstore::SpecHelpers.with_db("levels-keep", config) do |db, _path|
      put_batch(db, "k", 120)
      db.flush
      db.compact
      db.compact
      db.stats.levels.should eq([0, 0, 1])

      db.delete("k-040")
      db.flush
      put_batch(db, "j", 120)
      db.flush
      db.compact
      db.stats.levels.should eq([0, 1, 1])
      db.get("k-040").should be_nil
    end
  end

  it "drops a tombstone once it reaches the deepest level" do
    config = tiny_level_config
    Cinderstore::SpecHelpers.with_db("levels-drop", config) do |db, _path|
      put_batch(db, "k", 120)
      db.flush
      db.compact
      db.compact
      db.delete("k-040")
      db.flush
      put_batch(db, "j", 120)
      db.flush
      db.compact
      db.stats.levels.should eq([0, 1, 1])

      db.compact
      db.stats.levels.should eq([0, 0, 1])
      db.get("k-040").should be_nil
      db.scan.size.should eq(239)
    end
  end

  it "reads the newest value across three levels" do
    config = tiny_level_config
    Cinderstore::SpecHelpers.with_db("levels-newest", config) do |db, _path|
      put_batch(db, "k", 120)
      db.flush
      db.compact
      db.compact
      db.put("k-040", "newest")
      db.flush
      db.compact
      db.get("k-040").should eq("newest")
      db.scan.size.should eq(120)
    end
  end

  it "recovers a multi-level store after restart" do
    config = tiny_level_config
    Cinderstore::SpecHelpers.with_db_path("levels-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      put_batch(db, "k", 120)
      db.flush
      db.compact
      db.compact
      db.put("j-100", "later")
      db.flush
      db.compact
      db.stats.levels.should eq([0, 1, 1])
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.get("k-040").should eq("v40-" + "x" * 40)
      reopened.get("j-100").should eq("later")
      reopened.scan.size.should eq(121)
      reopened.close
    end
  end

  it "reports per level table counts in stats" do
    config = tiny_level_config
    Cinderstore::SpecHelpers.with_db("levels-stats", config) do |db, _path|
      put_batch(db, "k", 120)
      db.flush
      db.compact
      db.compact
      stats = db.stats
      stats.levels.should eq([0, 0, 1])
      stats.tables.should eq(1)
      stats.l0.should eq(0)
      stats.to_json.should contain("levels")
    end
  end
end
