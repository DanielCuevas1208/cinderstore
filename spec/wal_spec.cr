require "./spec_helper"

describe Cinderstore::Wal do
  it "replays a freshly written log" do
    path = File.join(Cinderstore::SpecHelpers.tmp_db_path("wal"), "000001.wal")
    Dir.mkdir_p(File.dirname(path))
    writer = Cinderstore::Wal::Writer.new(path, false)
    writer.append(Cinderstore::Entry.new("a", 1_i64, true, "one"))
    writer.append(Cinderstore::Entry.new("b", 2_i64, false, ""))
    writer.close

    mem = Cinderstore::MemTable.new
    seq = Cinderstore::Wal.recover(path, mem, 0_i64)
    seq.should eq(2_i64)
    mem.get("a").should eq("one")
    mem.get("b").should be_nil
    mem.get_entry("b").not_nil!.alive.should be_false
  end

  it "recovers nothing from a missing log" do
    mem = Cinderstore::MemTable.new
    Cinderstore::Wal.recover("no-such-file.wal", mem, 7_i64).should eq(7_i64)
    mem.empty?.should be_true
  end

  it "stops at a torn tail and keeps the intact prefix" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("wal")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000001.wal")
    writer = Cinderstore::Wal::Writer.new(path, false)
    writer.append(Cinderstore::Entry.new("alpha", 1_i64, true, "1"))
    writer.append(Cinderstore::Entry.new("beta", 2_i64, true, "2"))
    writer.append(Cinderstore::Entry.new("gamma", 3_i64, true, "3"))
    writer.close

    # Cut the last record in half. This simulates a torn write.
    Cinderstore::SpecHelpers.truncate(path, File.size(path) - 3)

    mem = Cinderstore::MemTable.new
    seq = Cinderstore::Wal.recover(path, mem, 0_i64)
    seq.should eq(2_i64)
    mem.get("alpha").should eq("1")
    mem.get("beta").should eq("2")
    mem.get("gamma").should be_nil
  end

  it "stops at a checksum mismatch" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("wal")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000001.wal")
    writer = Cinderstore::Wal::Writer.new(path, false)
    writer.append(Cinderstore::Entry.new("alpha", 1_i64, true, "1"))
    writer.close

    # Flip a byte inside the record body. The first nine bytes are the
    # header, so the payload starts at offset ten.
    bytes = File.read(path).to_slice.dup
    bytes[11] = (bytes[11] ^ 0xFF).to_u8
    File.open(path, "w") { |f| f.write(bytes) }

    mem = Cinderstore::MemTable.new
    Cinderstore::Wal.recover(path, mem, 0_i64)
    mem.empty?.should be_true
  end

  it "survives a restart through the database" do
    Cinderstore::SpecHelpers.with_db_path("wal-durable") do |path|
      db = Cinderstore::DB.new(path)
      db.put("persisted", "yes")
      db.close
      reopened = Cinderstore::DB.new(path)
      reopened.get("persisted").should eq("yes")
      reopened.close
    end
  end

  it "replays a checksum-free log" do
    path = File.join(Cinderstore::SpecHelpers.tmp_db_path("wal-fast"), "000001.wal")
    Dir.mkdir_p(File.dirname(path))
    writer = Cinderstore::Wal::Writer.new(path, false, false)
    writer.append(Cinderstore::Entry.new("a", 1_i64, true, "one"))
    writer.append(Cinderstore::Entry.new("b", 2_i64, false, ""))
    writer.close

    mem = Cinderstore::MemTable.new
    seq = Cinderstore::Wal.recover(path, mem, 0_i64)
    seq.should eq(2_i64)
    mem.get("a").should eq("one")
    mem.get("b").should be_nil
    mem.get_entry("b").not_nil!.alive.should be_false
  end

  it "stops at a torn tail in a checksum-free log" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("wal-fast")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000001.wal")
    writer = Cinderstore::Wal::Writer.new(path, false, false)
    writer.append(Cinderstore::Entry.new("alpha", 1_i64, true, "1"))
    writer.append(Cinderstore::Entry.new("beta", 2_i64, true, "2"))
    writer.append(Cinderstore::Entry.new("gamma", 3_i64, true, "3"))
    writer.close

    Cinderstore::SpecHelpers.truncate(path, File.size(path) - 3)

    mem = Cinderstore::MemTable.new
    seq = Cinderstore::Wal.recover(path, mem, 0_i64)
    seq.should eq(2_i64)
    mem.get("alpha").should eq("1")
    mem.get("beta").should eq("2")
    mem.get("gamma").should be_nil
  end

  it "reads a legacy log without a header as checksummed" do
    path = File.join(Cinderstore::SpecHelpers.tmp_db_path("wal-legacy"), "000001.wal")
    Dir.mkdir_p(File.dirname(path))
    File.open(path, "w") do |io|
      io.write(Cinderstore::Wal.encode(Cinderstore::Entry.new("old", 5_i64, true, "v")))
    end

    mem = Cinderstore::MemTable.new
    seq = Cinderstore::Wal.recover(path, mem, 0_i64)
    seq.should eq(5_i64)
    mem.get("old").should eq("v")
  end

  it "does not misread a checksum-free log as a legacy one" do
    path = File.join(Cinderstore::SpecHelpers.tmp_db_path("wal-header"), "000001.wal")
    Dir.mkdir_p(File.dirname(path))
    writer = Cinderstore::Wal::Writer.new(path, false, false)
    writer.append(Cinderstore::Entry.new("fast", 3_i64, true, "v"))
    writer.close

    mem = Cinderstore::MemTable.new
    Cinderstore::Wal.recover(path, mem, 0_i64)
    mem.get("fast").should eq("v")
  end
end
