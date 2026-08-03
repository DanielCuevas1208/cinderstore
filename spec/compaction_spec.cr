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

  it "cascades level-0 tables through the deeper levels" do
    config = Cinderstore::SpecHelpers.fast_config
    config.l1_compact_threshold = 2
    config.max_level = 3
    Cinderstore::SpecHelpers.with_db("compact-cascade", config) do |db, _path|
      db.put("a", "1")
      db.put("b", "2")
      db.flush
      db.put("c", "3")
      db.put("d", "4")
      db.flush
      db.compact
      db.stats.levels.should eq([0, 1])
      db.stats.l0.should eq(0)
      db.stats.l1.should eq(1)

      db.put("e", "5")
      db.put("f", "6")
      db.flush
      db.put("g", "7")
      db.put("h", "8")
      db.flush
      db.compact
      db.stats.levels.should eq([0, 0, 1])
      db.stats.l2.should eq(1)
      db.scan.map(&.[0]).should eq(%w[a b c d e f g h])
      db.get("e").should eq("5")
    end
  end

  it "keeps a tombstone while a deeper level still holds the key" do
    config = Cinderstore::SpecHelpers.fast_config
    config.l1_compact_threshold = 2
    config.max_level = 3
    Cinderstore::SpecHelpers.with_db("compact-guard", config) do |db, _path|
      # Build an old value for "k" at the deepest level.
      db.put("k", "old")
      db.put("a", "1")
      db.put("b", "2")
      db.put("c", "3")
      db.flush
      db.put("m", "4")
      db.put("n", "5")
      db.put("o", "6")
      db.put("p", "7")
      db.flush
      db.compact
      db.put("q", "8")
      db.put("r", "9")
      db.put("s", "10")
      db.put("t", "11")
      db.flush
      db.put("u", "12")
      db.put("v", "13")
      db.put("w", "14")
      db.put("x", "15")
      db.flush
      db.compact
      db.stats.l2.should eq(1)
      db.get("k").should eq("old")

      # Delete "k". The merge into level 1 must keep the tombstone, because
      # level 2 still holds the older value for "k".
      db.put("k", "new")
      db.delete("k")
      db.put("y", "16")
      db.put("z", "17")
      db.flush
      db.put("aa", "18")
      db.put("bb", "19")
      db.flush
      db.compact
      db.stats.levels.should eq([0, 1, 1])
      db.get("k").should be_nil
      db.get("y").should eq("16")
      db.scan.map(&.[0]).should eq(%w[a aa b bb c m n o p q r s t u v w x y z])
    end
  end

  it "drops a tombstone once the merge covers the deepest level" do
    config = Cinderstore::SpecHelpers.fast_config
    config.l1_compact_threshold = 2
    config.max_level = 3
    Cinderstore::SpecHelpers.with_db("compact-expire", config) do |db, _path|
      db.put("k", "old")
      db.put("a", "1")
      db.put("b", "2")
      db.put("c", "3")
      db.flush
      db.put("m", "4")
      db.put("n", "5")
      db.put("o", "6")
      db.put("p", "7")
      db.flush
      db.compact
      db.put("q", "8")
      db.put("r", "9")
      db.put("s", "10")
      db.put("t", "11")
      db.flush
      db.put("u", "12")
      db.put("v", "13")
      db.put("w", "14")
      db.put("x", "15")
      db.flush
      db.compact

      db.put("k", "new")
      db.delete("k")
      db.put("y", "16")
      db.put("z", "17")
      db.flush
      db.put("aa", "18")
      db.put("bb", "19")
      db.flush
      db.compact
      db.get("k").should be_nil

      # Two disjoint batches push level 1 past its threshold. The cascade
      # merges level 1 into level 2, the deepest level. Every copy of "k"
      # is inside the merge, so the tombstone is dropped.
      db.put("zz", "20")
      db.put("zza", "21")
      db.flush
      db.put("zzb", "22")
      db.put("zzc", "23")
      db.flush
      db.compact
      db.stats.levels.should eq([0, 0, 1])
      db.stats.entries.should eq(23)
      db.get("k").should be_nil
      db.scan.map(&.[0]).should eq(%w[a aa b bb c m n o p q r s t u v w x y z zz zza zzb zzc])
    end
  end

  it "recovers a multi-level layout after a restart" do
    config = Cinderstore::SpecHelpers.fast_config
    config.l1_compact_threshold = 2
    config.max_level = 3
    Cinderstore::SpecHelpers.with_db_path("compact-deep-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("a", "1")
      db.put("b", "2")
      db.flush
      db.put("c", "3")
      db.put("d", "4")
      db.flush
      db.compact
      db.put("e", "5")
      db.put("f", "6")
      db.flush
      db.put("g", "7")
      db.put("h", "8")
      db.flush
      db.compact
      db.stats.levels.should eq([0, 0, 1])
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.stats.levels.should eq([0, 0, 1])
      reopened.scan.map(&.[0]).should eq(%w[a b c d e f g h])
      reopened.get("f").should eq("6")
      reopened.close
    end
  end
end
