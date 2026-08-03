require "./spec_helper"

describe "Cinderstore checksum-free fast mode" do
  it "round trips values with checksums disabled" do
    config = Cinderstore::SpecHelpers.fast_config
    config.checksums = false
    Cinderstore::SpecHelpers.with_db("fast-basic", config) do |db, _path|
      db.put("alpha", "one")
      db.put("beta", "two")
      db.delete("beta")
      db.put("beta", "three")
      db.get("alpha").should eq("one")
      db.get("beta").should eq("three")
      db.scan.map(&.[0]).should eq(%w[alpha beta])
    end
  end

  it "flushes and compacts with checksums disabled" do
    config = Cinderstore::SpecHelpers.fast_config
    config.checksums = false
    Cinderstore::SpecHelpers.with_db("fast-flush", config) do |db, _path|
      6.times do |round|
        20.times { |i| db.put("k%03d" % (round * 20 + i), "r#{round}") }
        db.flush
      end
      db.compact
      db.stats.tables.should eq(1)
      db.stats.l1.should eq(1)
      db.scan.size.should eq(120)
      db.get("k099").should eq("r4")
    end
  end

  it "recovers a checksum-free database after a restart" do
    config = Cinderstore::SpecHelpers.fast_config
    config.checksums = false
    Cinderstore::SpecHelpers.with_db_path("fast-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("a", "1")
      db.put("b", "2")
      db.delete("a")
      db.flush
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.get("a").should be_nil
      reopened.get("b").should eq("2")
      reopened.stats.tables.should eq(1)
      reopened.scan.map(&.[0]).should eq(%w[b])
      reopened.close
    end
  end

  it "recovers a checksummed database with checksums disabled" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("fast-mix-on-off") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("a", "1")
      db.put("b", "2")
      db.flush
      db.close

      fast = Cinderstore::SpecHelpers.fast_config
      fast.checksums = false
      reopened = Cinderstore::DB.new(path, fast)
      reopened.get("a").should eq("1")
      reopened.get("b").should eq("2")
      reopened.scan.map(&.[0]).should eq(%w[a b])
      reopened.close
    end
  end

  it "recovers a checksum-free database with checksums enabled" do
    fast = Cinderstore::SpecHelpers.fast_config
    fast.checksums = false
    Cinderstore::SpecHelpers.with_db_path("fast-mix-off-on") do |path|
      db = Cinderstore::DB.new(path, fast)
      db.put("a", "1")
      db.put("b", "2")
      db.flush
      db.close

      checked = Cinderstore::SpecHelpers.fast_config
      reopened = Cinderstore::DB.new(path, checked)
      reopened.get("a").should eq("1")
      reopened.get("b").should eq("2")
      reopened.stats.tables.should eq(1)
      reopened.scan.map(&.[0]).should eq(%w[a b])
      reopened.close
    end
  end

  it "serves a snapshot on a checksum-free database" do
    config = Cinderstore::SpecHelpers.fast_config
    config.checksums = false
    Cinderstore::SpecHelpers.with_db("fast-snapshot", config) do |db, _path|
      db.put("a", "1")
      db.flush
      snap = db.snapshot
      db.put("b", "2")
      db.flush
      snap.get("a").should eq("1")
      snap.get("b").should be_nil
      snap.scan.map(&.[0]).should eq(%w[a])
      snap.release
    end
  end

  it "reads a mixed set of checksummed and fast tables" do
    checked = Cinderstore::SpecHelpers.fast_config
    fast = Cinderstore::SpecHelpers.fast_config
    fast.checksums = false
    Cinderstore::SpecHelpers.with_db_path("fast-mixed-tables") do |path|
      db = Cinderstore::DB.new(path, checked)
      db.put("a", "checked")
      db.flush
      db.close

      other = Cinderstore::DB.new(path, fast)
      other.put("b", "fast")
      other.flush
      other.get("a").should eq("checked")
      other.get("b").should eq("fast")
      other.scan.map(&.[0]).should eq(%w[a b])
      other.close
    end
  end

  it "stores fast tables with fewer bytes than checksummed tables" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("fast-size")
    Dir.mkdir_p(dir)
    entries = 300.times.map { |i| Cinderstore::Entry.new("key-%04d" % i, i.to_i64, true, "value-" + "x" * 40) }.to_a

    checked_path = File.join(dir, "000001.sst")
    File.open(checked_path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 1_i64, 128, 0.01, true)
      entries.each { |e| writer.add(e.key, e.value, e.seq, e.alive) }
      writer.finish
    end

    fast_path = File.join(dir, "000002.sst")
    File.open(fast_path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 2_i64, 128, 0.01, false)
      entries.each { |e| writer.add(e.key, e.value, e.seq, e.alive) }
      writer.finish
    end

    File.size(checked_path).should be > File.size(fast_path)

    reader = Cinderstore::SstableReader.new(fast_path, 2_i64, nil)
    reader.block_count.should be > 1
    read_all_entries(reader).should eq(entries)
    reader.close
  end

  it "leaves fast mode block corruption undetected by design" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("fast-corrupt")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000003.sst")
    entries = 100.times.map { |i| Cinderstore::Entry.new("key-%03d" % i, i.to_i64, true, "value-#{i}") }.to_a
    File.open(path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 3_i64, 64, 0.01, false)
      entries.each { |e| writer.add(e.key, e.value, e.seq, e.alive) }
      writer.finish
    end

    # Flip a byte inside the first block payload. Fast mode skips CRC32
    # verification, so the reader must not raise. The structural length
    # check still passes because the block size is unchanged.
    File.open(path, "r+") do |f|
      f.pos = 16
      byte = f.read_byte.not_nil!
      f.pos = 16
      f.write_byte((byte ^ 0xFF).to_u8)
    end

    reader = Cinderstore::SstableReader.new(path, 3_i64, nil)
    reader.load_block_entries(0)
    reader.close
  end
end

def read_all_entries(reader : Cinderstore::SstableReader)
  all = [] of Cinderstore::Entry
  reader.block_count.times do |i|
    all.concat(reader.load_block_entries(i))
  end
  all
end
