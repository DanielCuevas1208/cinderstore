require "./spec_helper"

describe "Cinderstore compaction" do
  it "is a no-op with fewer than two tables" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("compact-single", config) do |db, _path|
      db.put("a", "1")
      db.flush
      db.compact
      db.stats.tables.should eq(1)
      db.get("a").should eq("1")
    end
  end

  it "merges overlapping level-0 tables" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("compact-merge", config) do |db, _path|
      db.put("a", "a1")
      db.put("c", "c1")
      db.flush
      db.put("b", "b1")
      db.put("d", "d1")
      db.flush
      db.stats.tables.should eq(2)
      db.stats.l0.should eq(2)

      db.compact
      db.stats.tables.should eq(1)
      db.stats.l0.should eq(0)
      db.stats.l1.should eq(1)
      db.scan.map(&.[0]).should eq(%w[a b c d])
    end
  end

  it "keeps the newest value across tables after compaction" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("compact-newest", config) do |db, _path|
      db.put("k", "v1")
      db.flush
      db.put("k", "v2")
      db.flush
      db.get("k").should eq("v2")
      db.compact
      db.get("k").should eq("v2")
      db.scan.size.should eq(1)
    end
  end

  it "drops deleted keys during compaction" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("compact-delete", config) do |db, _path|
      db.put("keep1", "a")
      db.put("drop1", "a")
      db.put("keep2", "a")
      db.flush
      db.delete("drop1")
      db.delete("drop2")
      db.flush
      db.stats.entries.should eq(5)

      db.compact
      db.stats.tables.should eq(1)
      db.stats.l1.should eq(1)
      db.stats.entries.should eq(2)
      db.get("drop1").should be_nil
      db.get("keep1").should eq("a")
      db.scan.map(&.[0]).should eq(%w[keep1 keep2])
    end
  end

  it "drops a key whose newest entry is a tombstone" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("compact-fully-deleted", config) do |db, _path|
      db.put("gone", "v")
      db.flush
      db.delete("gone")
      db.flush
      db.compact
      db.stats.entries.should eq(0)
      db.stats.tables.should eq(0)
      db.get("gone").should be_nil
    end
  end

  it "keeps the store correct after restart following compaction" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("compact-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("a", "1")
      db.put("b", "2")
      db.flush
      db.delete("a")
      db.flush
      db.compact
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.get("a").should be_nil
      reopened.get("b").should eq("2")
      reopened.stats.tables.should eq(1)
      reopened.scan.map(&.[0]).should eq(%w[b])
      reopened.close
    end
  end

  it "handles many small flushes and a full merge" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("compact-many", config) do |db, _path|
      6.times do |round|
        base = round * 20
        20.times { |i| db.put("k%03d" % (base + i), "r#{round}") }
        db.flush
      end
      db.stats.tables.should eq(6)
      db.compact
      db.stats.tables.should eq(1)
      db.stats.l1.should eq(1)
      db.scan.size.should eq(120)
      db.get("k099").should eq("r4")
      db.get("k119").should eq("r5")
    end
  end

  it "splits a large merge across multiple level-1 tables" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("compact-split", config) do |db, _path|
      # Exceed DB::MAX_TABLE_ENTRIES across several flushes.
      5.times do |round|
        5_000.times { |i| db.put("k-%02d-%05d" % {round, i}, "v") }
        db.flush
      end
      db.compact
      db.stats.tables.should be > 1
      db.stats.l0.should eq(0)
      db.get("k-02-02500").should eq("v")
      db.scan.size.should eq(25_000)
    end
  end

  it "leaves disjoint level-1 tables in place during a level-0 merge" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("compact-incremental", config) do |db, _path|
      5.times { |i| db.put("r1-%02d" % i, "v") }
      db.flush
      5.times { |i| db.put("r1-%02d" % (i + 5), "v") }
      db.flush
      db.compact
      db.stats.l1.should eq(1)

      5.times { |i| db.put("r2-%02d" % i, "v") }
      db.flush
      5.times { |i| db.put("r2-%02d" % (i + 5), "v") }
      db.flush
      db.compact

      db.stats.tables.should eq(2)
      db.stats.l0.should eq(0)
      db.stats.l1.should eq(2)
      db.scan.size.should eq(20)
      db.get("r1-03").should eq("v")
      db.get("r2-07").should eq("v")
    end
  end

  it "rewrites only the tables that overlap a level-0 merge" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("compact-partial", config) do |db, _path|
      5.times { |i| db.put("left-%02d" % i, "v") }
      db.flush
      5.times { |i| db.put("left-%02d" % (i + 5), "v") }
      db.flush
      db.compact
      db.stats.l1.should eq(1)

      5.times { |i| db.put("mid-%02d" % i, "v") }
      db.flush
      5.times { |i| db.put("mid-%02d" % (i + 5), "v") }
      db.flush
      db.compact

      # The mid table overlaps the new level-0 pair, so it merges with
      # them. The left table stays untouched.
      db.stats.tables.should eq(2)
      db.stats.l1.should eq(2)
      db.scan.size.should eq(20)
      db.get("left-04").should eq("v")
      db.get("mid-09").should eq("v")
    end
  end

  it "cascades a full level into the next level" do
    config = Cinderstore::SpecHelpers.fast_config
    config.l1_compact_threshold = 2
    Cinderstore::SpecHelpers.with_db("compact-cascade", config) do |db, _path|
      5.times { |i| db.put("s1-%02d" % i, "v") }
      db.flush
      5.times { |i| db.put("s1-%02d" % (i + 5), "v") }
      db.flush
      db.compact
      db.stats.l1.should eq(1)

      5.times { |i| db.put("s2-%02d" % i, "v") }
      db.flush
      5.times { |i| db.put("s2-%02d" % (i + 5), "v") }
      db.flush
      db.compact

      db.stats.tables.should eq(1)
      db.stats.l0.should eq(0)
      db.stats.l1.should eq(0)
      db.stats.l2.should eq(1)
      db.scan.size.should eq(20)
      db.get("s1-04").should eq("v")
      db.get("s2-09").should eq("v")
    end
  end

  it "keeps tombstones while a deeper level may hold older data" do
    config = Cinderstore::SpecHelpers.fast_config
    config.l1_compact_threshold = 2
    Cinderstore::SpecHelpers.with_db("compact-tombstone-level", config) do |db, _path|
      2.times do |round|
        prefix = "s#{round + 1}"
        5.times { |i| db.put("#{prefix}-%02d" % i, "v") }
        db.flush
        5.times { |i| db.put("#{prefix}-%02d" % (i + 5), "v") }
        db.flush
        db.compact
      end
      # Level 2 now holds every key. Level 1 is empty.
      db.stats.l2.should eq(1)
      db.get("s1-00").should eq("v")

      # Two tombstones land at level 0. A level-0 merge cannot drop them,
      # because level 2 still holds older values for the same keys.
      db.delete("s1-00")
      db.flush
      db.delete("s1-01")
      db.flush
      db.compact
      db.get("s1-00").should be_nil
      db.get("s1-01").should be_nil
      db.stats.tables.should eq(2)
      db.stats.l1.should eq(1)
      db.stats.l2.should eq(1)

      # Feed level 1 to the threshold. Compaction now reaches the bottom
      # level and safely drops the tombstones.
      5.times { |i| db.put("s3-%02d" % i, "v") }
      db.flush
      5.times { |i| db.put("s3-%02d" % (i + 5), "v") }
      db.flush
      db.compact

      db.get("s1-00").should be_nil
      db.get("s1-01").should be_nil
      db.stats.l2.should eq(1)
      db.scan.size.should eq(28)
    end
  end

  it "keeps the store correct after restart following leveled compaction" do
    config = Cinderstore::SpecHelpers.fast_config
    config.l1_compact_threshold = 2
    Cinderstore::SpecHelpers.with_db_path("compact-level-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("a", "1")
      db.put("b", "2")
      db.flush
      db.put("c", "3")
      db.put("d", "4")
      db.flush
      db.compact

      db.put("e", "5")
      db.flush
      db.put("f", "6")
      db.flush
      db.compact

      db.stats.l2.should eq(1)
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.stats.l2.should eq(1)
      reopened.get("a").should eq("1")
      reopened.get("b").should eq("2")
      reopened.get("c").should eq("3")
      reopened.get("d").should eq("4")
      reopened.get("e").should eq("5")
      reopened.get("f").should eq("6")
      reopened.scan.map(&.[0]).should eq(%w[a b c d e f])
      reopened.close
    end
  end
end
