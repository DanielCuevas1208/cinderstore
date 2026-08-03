require "./spec_helper"

# Grants a test direct control over the table layout. The database opens
# against an empty directory first; the test then writes table files and
# injects references to them.
class LeveledHarness < Cinderstore::DB
  # Replaces the level layout. The caller must create every referenced
  # table file first.
  def inject_levels!(levels : Array(Array(Cinderstore::DB::TableRef)))
    @lock.synchronize do
      @levels = levels
      @seq = 10_000_i64
      @next_id = 20_000_i64
    end
  end
end

# Writes one sorted table into `path` and returns a live table reference.
private def make_table_ref(path : String, id : Int64, entries : Array(Cinderstore::Entry))
  file = File.join(path, "#{Cinderstore::Util.file_stem(id)}.sst")
  meta = nil
  File.open(file, "w") do |io|
    writer = Cinderstore::SstableWriter.new(io, id, 4096, 0.01)
    entries.each { |e| writer.add(e.key, e.value, e.seq, e.alive) }
    meta = writer.finish
  end
  m = meta.not_nil!
  Cinderstore::DB::TableRef.new(m.id, m.first, m.last, m.count, file)
end

# Polls until a condition holds, then fails if it does not within 5 seconds.
private def wait_for_compact(timeout : Time::Span = 5.seconds, &block : -> Bool) : Nil
  deadline = Time.instant + timeout
  until block.call
    raise "condition not met in time" if Time.instant >= deadline
    sleep 10.milliseconds
  end
end

# Writes `count` keys with values of about `value_size` bytes.
private def write_batch(db : Cinderstore::DB, prefix : String, count : Int32, value_size : Int32) : Nil
  count.times { |i| db.put("#{prefix}-%04d" % i, "v" * value_size) }
end

describe "Cinderstore leveled compaction" do
  it "drains level-0 tables into level 1" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("lvl-drain", config) do |db, _path|
      db.put("a", "1")
      db.flush
      db.put("b", "2")
      db.flush
      db.stats.l0.should eq(2)

      db.compact
      db.stats.l0.should eq(0)
      db.stats.l1.should eq(1)
      db.stats.levels.should eq([0, 1])
      db.scan.map(&.[0]).should eq(%w[a b])
    end
  end

  it "builds multiple levels when data exceeds the level targets" do
    config = Cinderstore::SpecHelpers.fast_config
    config.base_level_bytes = 500
    config.level_multiplier = 4
    Cinderstore::SpecHelpers.with_db("lvl-multilevel", config) do |db, _path|
      5.times do |round|
        write_batch(db, "k#{round}", 30, 50)
        db.flush
        write_batch(db, "k#{round}b", 30, 50)
        db.flush
        db.compact
      end
      stats = db.stats
      stats.l0.should eq(0)
      stats.levels.size.should be >= 3
      stats.levels[1..].sum.should be > 0
      db.scan.size.should eq(5 * 60)
    end
  end

  it "keeps every level except level 0 non-overlapping" do
    config = Cinderstore::SpecHelpers.fast_config
    config.base_level_bytes = 500
    config.level_multiplier = 4
    Cinderstore::SpecHelpers.with_db_path("lvl-nonoverlap") do |path|
      db = Cinderstore::DB.new(path, config)
      begin
        4.times do |round|
          write_batch(db, "r#{round}", 40, 50)
          db.flush
          write_batch(db, "r#{round}b", 40, 50)
          db.flush
          db.compact
        end
        manifest = Cinderstore::Manifest.load(File.join(path, "MANIFEST"))
        manifest.levels.size.should be >= 3
        manifest.levels[1..].each do |level|
          (0...(level.size - 1)).each do |i|
            level[i].last.should be < level[i + 1].first
          end
        end
        db.scan.size.should eq(4 * 80)
      ensure
        db.close rescue nil
      end
    end
  end

  it "keeps tombstones while a deeper level still holds older data" do
    path = Cinderstore::SpecHelpers.tmp_db_path("lvl-keep")
    config = Cinderstore::SpecHelpers.fast_config
    config.base_level_bytes = 1
    config.level_multiplier = 1_000_000
    db = LeveledHarness.new(path, config)
    begin
      top = make_table_ref(path, 100_i64, [
        Cinderstore::Entry.new("aaa", 30_i64, false, ""),
        Cinderstore::Entry.new("bbb", 31_i64, true, "2"),
      ])
      middle = make_table_ref(path, 200_i64, [
        Cinderstore::Entry.new("aaa", 20_i64, true, "v2"),
      ])
      bottom = make_table_ref(path, 300_i64, [
        Cinderstore::Entry.new("aaa", 10_i64, true, "v1"),
      ])
      db.inject_levels!([[] of Cinderstore::DB::TableRef, [top], [middle], [bottom]])

      db.compact
      # Only level 1 moved into level 2. The tombstone had to survive,
      # because level 3 still stores an older version of "aaa".
      db.stats.levels.should eq([0, 0, 1, 1])
      db.get("aaa").should be_nil
      db.get("bbb").should eq("2")
    ensure
      db.close rescue nil
      FileUtils.rm_rf(path)
    end
  end

  it "drops tombstones when the target level is the bottom" do
    path = Cinderstore::SpecHelpers.tmp_db_path("lvl-drop")
    config = Cinderstore::SpecHelpers.fast_config
    config.base_level_bytes = 1
    config.level_multiplier = 1_000_000
    db = LeveledHarness.new(path, config)
    begin
      top = make_table_ref(path, 100_i64, [
        Cinderstore::Entry.new("aaa", 30_i64, false, ""),
        Cinderstore::Entry.new("bbb", 31_i64, true, "2"),
      ])
      bottom = make_table_ref(path, 200_i64, [
        Cinderstore::Entry.new("aaa", 10_i64, true, "v1"),
        Cinderstore::Entry.new("ccc", 12_i64, true, "3"),
      ])
      db.inject_levels!([[] of Cinderstore::DB::TableRef, [top], [bottom]])

      db.compact
      # The tombstone and the old value cancel out, so "aaa" vanishes.
      db.stats.levels.should eq([0, 0, 1])
      db.stats.entries.should eq(2)
      db.get("aaa").should be_nil
      db.get("bbb").should eq("2")
      db.get("ccc").should eq("3")
      db.scan.map(&.[0]).should eq(%w[bbb ccc])
    ensure
      db.close rescue nil
      FileUtils.rm_rf(path)
    end
  end

  it "honors the configured threshold for background compaction" do
    config = Cinderstore::SpecHelpers.fast_config
    config.compact_on_flush = true
    config.l0_compact_threshold = 3
    Cinderstore::SpecHelpers.with_db("lvl-background", config) do |db, _path|
      db.put("a", "1")
      db.flush
      db.put("b", "2")
      db.flush
      db.stats.l0.should eq(2)

      db.put("c", "3")
      db.flush
      wait_for_compact { db.stats.l0 == 0 }
      db.stats.l1.should eq(1)
      db.scan.map(&.[0]).should eq(%w[a b c])
    end
  end

  it "restores the level layout after a restart" do
    config = Cinderstore::SpecHelpers.fast_config
    config.base_level_bytes = 800
    config.level_multiplier = 4
    Cinderstore::SpecHelpers.with_db_path("lvl-recovery") do |path|
      db = Cinderstore::DB.new(path, config)
      3.times do |round|
        write_batch(db, "r#{round}", 40, 50)
        db.flush
        write_batch(db, "r#{round}b", 40, 50)
        db.flush
        db.compact
      end
      before = db.stats.levels
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.stats.levels.should eq(before)
      reopened.scan.size.should eq(3 * 80)
      reopened.close
    end
  end

  it "keeps deep table files alive while a snapshot holds them" do
    config = Cinderstore::SpecHelpers.fast_config
    config.base_level_bytes = 600
    config.level_multiplier = 4
    Cinderstore::SpecHelpers.with_db("lvl-snapdeep", config) do |db, _path|
      2.times do |round|
        write_batch(db, "r#{round}", 30, 50)
        db.flush
        write_batch(db, "r#{round}b", 30, 50)
        db.flush
        db.compact
      end
      snap = db.snapshot
      snapshot_rows = snap.count

      write_batch(db, "r2", 30, 50)
      db.flush
      write_batch(db, "r2b", 30, 50)
      db.flush
      db.compact

      snap.count.should eq(snapshot_rows)
      db.scan.size.should eq(3 * 60)
      snap.release
      db.get("r2-0000").should eq("v" * 50)
    end
  end

  it "matches a reference model across random writes, deletes, flushes, and compactions" do
    config = Cinderstore::SpecHelpers.fast_config
    config.base_level_bytes = 800
    config.level_multiplier = 4
    Cinderstore::SpecHelpers.with_db("lvl-model", config) do |db, _path|
      rng = Random.new(0xC1DE_5EED)
      keys = (0...40).map { |i| "key-%03d" % i }
      model = {} of String => String

      300.times do
        case rng.rand(10)
        when 0, 1, 2, 3, 4
          key = keys[rng.rand(keys.size)]
          value = "v-#{rng.rand(10_000)}"
          db.put(key, value)
          model[key] = value
        when 5, 6
          key = keys[rng.rand(keys.size)]
          db.delete(key)
          model.delete(key)
        when 7
          db.flush
        when 8
          db.compact
        end
        if rng.rand(25) == 0
          db.scan.should eq(model.to_a.sort)
        end
      end

      db.flush
      db.compact
      db.scan.should eq(model.to_a.sort)
      db.stats.l0.should eq(0)
    end
  end

  it "reports per-level counts in stats" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("lvl-stats", config) do |db, _path|
      db.put("a", "1")
      db.flush
      db.put("b", "2")
      db.flush
      db.compact
      stats = db.stats
      stats.levels.should eq([0, 1])
      stats.to_h["levels"].should eq([0, 1])
      stats.to_json.should contain("\"levels\"")
    end
  end
end
