require "./spec_helper"

private def manifest_for(path : String) : Cinderstore::Manifest
  Cinderstore::Manifest.load(File.join(path, "MANIFEST"))
end

private def level_ids(path : String, level : Int32) : Array(Int64)
  manifest_for(path).levels[level].map(&.id)
end

private def table_entries(path : String, info : Cinderstore::Manifest::TableInfo)
  sst = File.join(path, "#{Cinderstore::Util.file_stem(info.id)}.sst")
  reader = Cinderstore::SstableReader.new(sst, info.id, nil)
  entries = [] of Cinderstore::Entry
  reader.block_count.times do |i|
    entries.concat(reader.load_block_entries(i))
  end
  reader.close
  entries
end

describe "Cinderstore leveled compaction" do
  it "moves a single level-0 table without rewriting it" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("leveled-move") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("x", "1")
      db.flush
      id = level_ids(path, 0).first
      db.compact
      db.stats.l0.should eq(0)
      db.stats.l1.should eq(1)
      level_ids(path, 1).should eq([id])
      db.close
    end
  end

  it "keeps non-overlapping level-1 tables untouched" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("leveled-keep") do |path|
      db = Cinderstore::DB.new(path, config)
      %w[a01 a02 a03 a04 a05 a06 a07 a08 a09 a10 a11 a12 a13].each { |k| db.put(k, "v") }
      db.flush
      db.compact
      kept_id = level_ids(path, 1).first

      %w[b01 b02 b03 b04 b05 b06 b07 b08 b09 b10 b11 b12 b13].each { |k| db.put(k, "v") }
      db.flush
      db.compact

      ids = level_ids(path, 1)
      ids.size.should eq(2)
      ids.should contain(kept_id)
      (ids - [kept_id]).size.should eq(1)
      db.stats.l0.should eq(0)
      db.scan.map(&.[0]).should eq(
        %w[a01 a02 a03 a04 a05 a06 a07 a08 a09 a10 a11 a12 a13
          b01 b02 b03 b04 b05 b06 b07 b08 b09 b10 b11 b12 b13]
      )
      db.close
    end
  end

  it "cascades an oversized level into the next level" do
    config = Cinderstore::SpecHelpers.fast_config
    config.max_bytes_per_level = 512
    Cinderstore::SpecHelpers.with_db_path("leveled-cascade") do |path|
      db = Cinderstore::DB.new(path, config)
      40.times { |i| db.put("k%03d" % i, "value-#{i}") }
      db.flush
      db.compact
      db.stats.l0.should eq(0)
      db.stats.levels[2].should eq(1)
      db.scan.size.should eq(40)
      db.get("k000").should eq("value-0")
      db.get("k039").should eq("value-39")
      db.close
    end
  end

  it "merges a multi-table level down through the cascade" do
    config = Cinderstore::SpecHelpers.fast_config
    config.max_bytes_per_level = 2000
    Cinderstore::SpecHelpers.with_db_path("leveled-merge") do |path|
      db = Cinderstore::DB.new(path, config)
      30.times { |i| db.put("a-%03d" % i, "value-#{i}-" + "y" * 24) }
      db.flush
      db.compact
      db.stats.l1.should eq(1)

      30.times { |i| db.put("b-%03d" % i, "value-#{i}-" + "y" * 24) }
      db.flush
      db.compact

      db.stats.l0.should eq(0)
      db.stats.levels[2].should eq(1)
      db.scan.size.should eq(60)
      db.get("a-000").should eq("value-0-" + "y" * 24)
      db.get("b-029").should eq("value-29-" + "y" * 24)
      db.close
    end
  end

  it "preserves tombstones when a deeper level holds data" do
    config = Cinderstore::SpecHelpers.fast_config
    config.max_bytes_per_level = 512
    Cinderstore::SpecHelpers.with_db_path("leveled-tombstone") do |path|
      db = Cinderstore::DB.new(path, config)
      40.times { |i| db.put("k%03d" % i, "v#{i}") }
      db.flush
      db.compact
      db.stats.levels[2].should eq(1)

      db.delete("k005")
      db.delete("k010")
      db.put("k040", "v40")
      db.flush
      db.put("k041", "v41")
      db.flush
      db.compact

      db.stats.l1.should be > 0
      db.stats.levels[2].should eq(1)
      db.get("k005").should be_nil
      db.get("k010").should be_nil
      db.scan.size.should eq(40)

      tombstones = 0
      manifest_for(path).levels[1].each do |info|
        table_entries(path, info).each do |entry|
          tombstones += 1 unless entry.alive
        end
      end
      tombstones.should eq(2)
      db.close
    end
  end

  it "restores a multi-level layout after a restart" do
    config = Cinderstore::SpecHelpers.fast_config
    config.max_bytes_per_level = 512
    Cinderstore::SpecHelpers.with_db_path("leveled-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      40.times { |i| db.put("k%03d" % i, "v#{i}") }
      db.flush
      db.compact
      db.stats.levels[2].should eq(1)
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.stats.l1.should eq(0)
      reopened.stats.levels[2].should eq(1)
      reopened.scan.size.should eq(40)
      reopened.get("k020").should eq("v20")
      reopened.close
    end
  end

  it "serves a consistent snapshot while tables move between levels" do
    config = Cinderstore::SpecHelpers.fast_config
    config.max_bytes_per_level = 512
    Cinderstore::SpecHelpers.with_db_path("leveled-snapshot") do |path|
      db = Cinderstore::DB.new(path, config)
      40.times { |i| db.put("k%03d" % i, "v#{i}") }
      db.flush
      db.compact

      snap = db.snapshot
      snap.count.should eq(40_i64)

      20.times { |i| db.put("k%03d" % (40 + i), "v#{40 + i}") }
      db.flush
      db.compact

      db.scan.size.should eq(60)
      snap.count.should eq(40_i64)
      snap.get("k039").should eq("v39")
      snap.get("k040").should be_nil
      snap.release
      db.close
    end
  end
end
