require "./spec_helper"

describe "Cinderstore fast mode" do
  it "stores and reads values without checksums" do
    config = Cinderstore::SpecHelpers.fast_config
    config.checksums = false
    Cinderstore::SpecHelpers.with_db("fast-basic", config) do |db, _path|
      db.put("a", "1")
      db.put("b", "2")
      db.get("a").should eq("1")
      db.get("b").should eq("2")
      db.get("c").should be_nil
    end
  end

  it "recovers writes after a restart" do
    config = Cinderstore::SpecHelpers.fast_config
    config.checksums = false
    Cinderstore::SpecHelpers.with_db_path("fast-restart") do |path|
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

  it "flushes into a table and reads it back" do
    config = Cinderstore::SpecHelpers.fast_config
    config.checksums = false
    Cinderstore::SpecHelpers.with_db("fast-flush", config) do |db, _path|
      20.times { |i| db.put("k%02d" % i, "v#{i}") }
      db.flush
      db.stats.tables.should eq(1)
      db.scan.size.should eq(20)
      db.get("k10").should eq("v10")
    end
  end

  it "compacts fast tables into a valid level-1 set" do
    config = Cinderstore::SpecHelpers.fast_config
    config.checksums = false
    Cinderstore::SpecHelpers.with_db("fast-compact", config) do |db, _path|
      db.put("a", "1")
      db.flush
      db.put("b", "2")
      db.flush
      db.compact
      db.stats.l1.should eq(1)
      db.get("a").should eq("1")
      db.get("b").should eq("2")
      db.scan.size.should eq(2)
    end
  end

  it "keeps snapshots consistent in fast mode" do
    config = Cinderstore::SpecHelpers.fast_config
    config.checksums = false
    Cinderstore::SpecHelpers.with_db("fast-snapshot", config) do |db, _path|
      db.put("a", "old")
      snap = db.snapshot
      db.put("b", "new")
      db.flush
      snap.get("a").should eq("old")
      snap.get("b").should be_nil
      snap.count.should eq(1_i64)
      db.scan.size.should eq(2)
    end
  end

  it "writes smaller tables than checksummed mode" do
    entries = 300.times.map { |i| Cinderstore::Entry.new("key-%04d" % i, i.to_i64, true, "value-#{i}") }.to_a
    dir = Cinderstore::SpecHelpers.tmp_db_path("fast-size")
    Dir.mkdir_p(dir)
    checksummed_path = File.join(dir, "000001.sst")
    fast_path = File.join(dir, "000002.sst")

    File.open(checksummed_path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 1_i64, 256, 0.01, true)
      entries.each { |entry| writer.add(entry.key, entry.value, entry.seq, entry.alive) }
      writer.finish
    end
    File.open(fast_path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 2_i64, 256, 0.01, false)
      entries.each { |entry| writer.add(entry.key, entry.value, entry.seq, entry.alive) }
      writer.finish
    end

    File.size(fast_path).should be < File.size(checksummed_path)
  end

  it "round trips a fast table through a reader" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("fast-table")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000001.sst")
    entries = 300.times.map { |i| Cinderstore::Entry.new("key-%04d" % i, i.to_i64, true, "value-#{i}") }.to_a
    File.open(path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 1_i64, 128, 0.01, false)
      entries.each { |entry| writer.add(entry.key, entry.value, entry.seq, entry.alive) }
      writer.finish
    end

    reader = Cinderstore::SstableReader.new(path, 1_i64, nil)
    all = [] of Cinderstore::Entry
    reader.block_count.times { |i| all.concat(reader.load_block_entries(i)) }
    all.should eq(entries)
    reader.close
  end

  it "keeps the intact prefix of a torn fast log" do
    config = Cinderstore::SpecHelpers.fast_config
    config.checksums = false
    Cinderstore::SpecHelpers.with_db_path("fast-torn") do |path|
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

  it "mixes fast and checksummed tables in one database" do
    Cinderstore::SpecHelpers.with_db_path("fast-mix") do |path|
      db = Cinderstore::DB.new(path, Cinderstore::SpecHelpers.fast_config)
      db.put("a", "1")
      db.put("b", "2")
      db.flush
      db.close

      fast_config = Cinderstore::SpecHelpers.fast_config
      fast_config.checksums = false
      reopened = Cinderstore::DB.new(path, fast_config)
      reopened.put("c", "3")
      reopened.put("d", "4")
      reopened.flush
      reopened.scan.size.should eq(4)
      reopened.get("a").should eq("1")
      reopened.get("d").should eq("4")
      reopened.close

      again = Cinderstore::DB.new(path, Cinderstore::SpecHelpers.fast_config)
      again.scan.size.should eq(4)
      again.close
    end
  end
end
