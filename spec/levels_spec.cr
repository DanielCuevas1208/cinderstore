require "./spec_helper"

# Polls until `block` returns true. Used for asynchronous background work.
private def wait_until(timeout : Time::Span = 5.seconds, &block : -> Bool) : Nil
  deadline = Time.instant + timeout
  until block.call
    raise "condition not met in time" if Time.instant >= deadline
    sleep 10.milliseconds
  end
end

# A config that compacts on small flushes and small level targets.
private def leveled_config(l0 : Int32 = 2, memtable : Int64 = 2_000,
                           ratio : Float64 = 2.0, levels : Int32 = 4) : Cinderstore::DB::Config
  config = Cinderstore::SpecHelpers.fast_config
  config.l0_compact_threshold = l0
  config.memtable_limit = memtable
  config.level_ratio = ratio
  config.max_levels = levels
  config
end

describe "Cinderstore leveled compaction" do
  it "is a no-op when no level needs compaction" do
    config = leveled_config
    Cinderstore::SpecHelpers.with_db("levels-nothing", config) do |db, _path|
      db.compact_levels.should be_false
      db.put("a", "1")
      db.compact_levels.should be_false
    end
  end

  it "moves level-0 tables into level 1 at the count threshold" do
    config = leveled_config
    Cinderstore::SpecHelpers.with_db("levels-l0", config) do |db, _path|
      db.put("a", "1")
      db.put("b", "2")
      db.flush
      db.put("c", "3")
      db.flush
      db.stats.l0.should eq(2)

      db.compact_levels.should be_true
      db.stats.l0.should eq(0)
      db.stats.l1.should eq(1)
      db.get("a").should eq("1")
      db.get("c").should eq("3")
      db.scan.map(&.[0]).should eq(%w[a b c])
    end
  end

  it "cascades data through several levels by size target" do
    config = leveled_config(ratio: 2.0, memtable: 2_000)
    Cinderstore::SpecHelpers.with_db("levels-cascade", config) do |db, _path|
      6.times do |batch|
        40.times { |i| db.put("k-%02d-%02d" % {batch, i}, "value-" + "x" * 40) }
        db.flush
      end

      db.compact_levels.should be_true

      stats = db.stats
      stats.l0.should eq(0)
      # The deepest levels must hold tables. Level 2 is reached because the
      # first level exceeds its small target.
      stats.level_counts.size.should be >= 3
      db.scan.size.should eq(240)
    end
  end

  it "keeps a tombstone while older data lives deeper" do
    config = leveled_config(ratio: 2.0, memtable: 2_000)
    Cinderstore::SpecHelpers.with_db("levels-tombstone", config) do |db, _path|
      6.times do |batch|
        40.times { |i| db.put("k-%02d-%02d" % {batch, i}, "value-" + "x" * 40) }
        db.flush
      end
      db.compact_levels

      db.delete("k-00-00")
      db.flush
      db.compact_levels

      # The tombstone must hide the old copy that lives in a deeper level.
      db.get("k-00-00").should be_nil
      db.scan.map(&.[0]).should_not contain("k-00-00")

      # A full merge drops the tombstone and the hidden copy for good.
      db.compact
      db.get("k-00-00").should be_nil
      db.scan.map(&.[0]).should_not contain("k-00-00")
    end
  end

  it "does not resurrect a key after repeated level compaction" do
    config = leveled_config(ratio: 2.0, memtable: 2_000)
    Cinderstore::SpecHelpers.with_db("levels-resurrect", config) do |db, _path|
      db.put("gone", "old")
      db.flush
      5.times do |batch|
        40.times { |i| db.put("pad-%02d-%02d" % {batch, i}, "value-" + "x" * 40) }
        db.flush
      end
      db.compact_levels

      db.delete("gone")
      db.flush
      db.compact_levels

      3.times do
        db.compact_levels
        db.get("gone").should be_nil
        db.scan.map(&.[0]).should_not contain("gone")
      end
    end
  end

  it "keeps reads correct across every level" do
    config = leveled_config(ratio: 2.0, memtable: 2_000)
    Cinderstore::SpecHelpers.with_db("levels-reads", config) do |db, _path|
      6.times do |batch|
        40.times { |i| db.put("k-%02d-%02d" % {batch, i}, "v%02d-%02d" % {batch, i}) }
        db.flush
      end
      db.compact_levels

      db.get("k-03-17").should eq("v03-17")
      db.get("k-05-39").should eq("v05-39")
      db.get("k-00-00").should eq("v00-00")
      db.get("missing").should be_nil
      db.scan.size.should eq(240)
    end
  end

  it "survives a restart with several levels" do
    config = leveled_config(ratio: 2.0, memtable: 2_000)
    Cinderstore::SpecHelpers.with_db_path("levels-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      6.times do |batch|
        40.times { |i| db.put("k-%02d-%02d" % {batch, i}, "v%02d-%02d" % {batch, i}) }
        db.flush
      end
      db.compact_levels
      counts = db.stats.level_counts
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.stats.level_counts.should eq(counts)
      reopened.scan.size.should eq(240)
      reopened.get("k-02-05").should eq("v02-05")
      reopened.close
    end
  end

  it "never creates more levels than the configured maximum" do
    config = leveled_config(levels: 3)
    Cinderstore::SpecHelpers.with_db("levels-cap", config) do |db, _path|
      8.times do |batch|
        50.times { |i| db.put("k-%02d-%02d" % {batch, i}, "value-" + "x" * 60) }
        db.flush
      end
      db.compact_levels
      db.stats.level_counts.size.should be <= 3
      db.scan.size.should eq(400)
    end
  end

  it "supports snapshots across several levels" do
    config = leveled_config(ratio: 2.0, memtable: 2_000)
    Cinderstore::SpecHelpers.with_db("levels-snapshot", config) do |db, _path|
      6.times do |batch|
        40.times { |i| db.put("k-%02d-%02d" % {batch, i}, "v%02d-%02d" % {batch, i}) }
        db.flush
      end
      db.compact_levels

      snap = db.snapshot
      db.put("new-key", "new-value")
      db.flush
      db.compact_levels

      snap.get("k-04-04").should eq("v04-04")
      snap.get("new-key").should be_nil
      snap.count.should eq(240_i64)
      db.get("new-key").should eq("new-value")
      snap.release
    end
  end

  it "runs background compaction automatically when enabled" do
    config = Cinderstore::SpecHelpers.small_config(memtable_limit: 2_000)
    config.l0_compact_threshold = 2
    config.compact_on_flush = true
    config.level_ratio = 2.0
    config.max_levels = 4
    Cinderstore::SpecHelpers.with_db("levels-background", config) do |db, _path|
      6.times do |batch|
        40.times { |i| db.put("k-%02d-%02d" % {batch, i}, "value-" + "x" * 40) }
        db.flush
      end
      wait_until { db.stats.l0 == 0 && db.stats.tables > 0 }
      db.scan.size.should eq(240)
    end
  end

  it "respects level targets after compaction" do
    config = leveled_config(ratio: 2.0, memtable: 2_000)
    Cinderstore::SpecHelpers.with_db("levels-targets", config) do |db, _path|
      6.times do |batch|
        40.times { |i| db.put("k-%02d-%02d" % {batch, i}, "value-" + "x" * 40) }
        db.flush
      end
      db.compact_levels.should be_true
      db.compact_levels.should be_false
      db.compact_levels.should be_false
      db.scan.size.should eq(240)
    end
  end
end
