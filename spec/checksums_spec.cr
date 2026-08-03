require "./spec_helper"

# Flips one byte of `path` at the first occurrence of `needle`.
def corrupt_bytes_at(path : String, needle : String) : Nil
  data = File.read(path).to_slice.dup
  target = needle.to_slice
  idx = (0..data.size - target.size).find do |i|
    target.size.times.all? { |j| data[i + j] == target[j] }
  end
  raise "pattern not found in #{path}" unless idx
  data[idx] = (data[idx] ^ 0xFF).to_u8
  File.open(path, "w") { |f| f.write(data) }
end

describe "Cinderstore checksum-free fast mode" do
  it "stores, flushes, compacts, and recovers data without checksums" do
    config = Cinderstore::SpecHelpers.fast_config
    config.checksums = false
    Cinderstore::SpecHelpers.with_db_path("fast-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("a", "1")
      db.put("b", "2")
      db.put("c", "3")
      db.flush
      db.delete("b")
      db.flush
      db.compact
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.get("a").should eq("1")
      reopened.get("b").should be_nil
      reopened.get("c").should eq("3")
      reopened.scan.map(&.[0]).should eq(%w[a c])
      reopened.close
    end
  end

  it "reads checksummed data with verification disabled" do
    write_config = Cinderstore::SpecHelpers.fast_config
    read_config = Cinderstore::SpecHelpers.fast_config
    read_config.checksums = false
    Cinderstore::SpecHelpers.with_db_path("fast-read-checksummed") do |path|
      db = Cinderstore::DB.new(path, write_config)
      db.put("a", "1")
      db.put("b", "2")
      db.flush
      db.compact
      db.close

      reopened = Cinderstore::DB.new(path, read_config)
      reopened.get("a").should eq("1")
      reopened.get("b").should eq("2")
      reopened.close
    end
  end

  it "reads checksum-free data with verification enabled" do
    write_config = Cinderstore::SpecHelpers.fast_config
    write_config.checksums = false
    read_config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("verify-read-checksumfree") do |path|
      db = Cinderstore::DB.new(path, write_config)
      db.put("a", "1")
      db.put("b", "2")
      db.flush
      db.compact
      db.close

      reopened = Cinderstore::DB.new(path, read_config)
      reopened.get("a").should eq("1")
      reopened.get("b").should eq("2")
      reopened.scan.map(&.[0]).should eq(%w[a b])
      reopened.close
    end
  end

  it "takes and reads a snapshot in fast mode" do
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
      db.scan.map(&.[0]).should eq(%w[a b])
    end
  end

  it "writes a zero checksum for each wal record in fast mode" do
    record = Cinderstore::Wal.encode(Cinderstore::Entry.new("a", 1_i64, true, "one"), false)
    record[-4, 4].should eq(Bytes.new(4, 0_u8))
  end

  it "replays a checksum-free wal with verification disabled" do
    path = File.join(Cinderstore::SpecHelpers.tmp_db_path("wal-fast"), "000001.wal")
    Dir.mkdir_p(File.dirname(path))
    writer = Cinderstore::Wal::Writer.new(path, false, false)
    writer.append(Cinderstore::Entry.new("a", 1_i64, true, "one"))
    writer.append(Cinderstore::Entry.new("b", 2_i64, false, ""))
    writer.close

    mem = Cinderstore::MemTable.new
    seq = Cinderstore::Wal.recover(path, mem, 0_i64, false)
    seq.should eq(2_i64)
    mem.get("a").should eq("one")
    mem.get("b").should be_nil
  end

  it "replays a checksum-free wal with verification enabled" do
    path = File.join(Cinderstore::SpecHelpers.tmp_db_path("wal-fast-verify"), "000001.wal")
    Dir.mkdir_p(File.dirname(path))
    writer = Cinderstore::Wal::Writer.new(path, false, false)
    writer.append(Cinderstore::Entry.new("a", 1_i64, true, "one"))
    writer.close

    mem = Cinderstore::MemTable.new
    Cinderstore::Wal.recover(path, mem, 0_i64, true).should eq(1_i64)
    mem.get("a").should eq("one")
  end

  it "stops at a torn tail in fast mode" do
    path = File.join(Cinderstore::SpecHelpers.tmp_db_path("wal-fast-torn"), "000001.wal")
    Dir.mkdir_p(File.dirname(path))
    writer = Cinderstore::Wal::Writer.new(path, false, false)
    writer.append(Cinderstore::Entry.new("alpha", 1_i64, true, "1"))
    writer.append(Cinderstore::Entry.new("beta", 2_i64, true, "2"))
    writer.append(Cinderstore::Entry.new("gamma", 3_i64, true, "3"))
    writer.close

    Cinderstore::SpecHelpers.truncate(path, File.size(path) - 3)

    mem = Cinderstore::MemTable.new
    seq = Cinderstore::Wal.recover(path, mem, 0_i64, false)
    seq.should eq(2_i64)
    mem.get("alpha").should eq("1")
    mem.get("beta").should eq("2")
    mem.get("gamma").should be_nil
  end

  it "writes zero checksums in a fast table and reads them back" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("table-fast")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000007.sst")
    entries = 50.times.map { |i| Cinderstore::Entry.new("key-%03d" % i, i.to_i64, true, "value-%03d" % i) }.to_a
    File.open(path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 7_i64, 64, 0.01, false)
      entries.each { |entry| writer.add(entry.key, entry.value, entry.seq, entry.alive) }
      writer.finish
    end

    reader = Cinderstore::SstableReader.new(path, 7_i64, nil, false)
    all = [] of Cinderstore::Entry
    reader.block_count.times { |i| all.concat(reader.load_block_entries(i)) }
    all.should eq(entries)
    reader.close
  end

  it "skips block verification on a corrupted fast table" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("table-fast-corrupt")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000007.sst")
    entries = [Cinderstore::Entry.new("a", 1_i64, true, "value-0000")]
    File.open(path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 7_i64, 64, 0.01, false)
      entries.each { |entry| writer.add(entry.key, entry.value, entry.seq, entry.alive) }
      writer.finish
    end

    corrupt_bytes_at(path, "value-0000")

    reader = Cinderstore::SstableReader.new(path, 7_i64, nil, false)
    reader.block_count.times { |i| reader.load_block_entries(i) }
    reader.close
  end

  it "detects block corruption when checksums are enabled" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("table-verify-corrupt")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000007.sst")
    entries = [Cinderstore::Entry.new("a", 1_i64, true, "value-0000")]
    File.open(path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 7_i64, 64, 0.01, true)
      entries.each { |entry| writer.add(entry.key, entry.value, entry.seq, entry.alive) }
      writer.finish
    end

    corrupt_bytes_at(path, "value-0000")

    reader = Cinderstore::SstableReader.new(path, 7_i64, nil, true)
    expect_raises(Cinderstore::CorruptDataError) do
      reader.load_block_entries(0)
    end
  end
end
