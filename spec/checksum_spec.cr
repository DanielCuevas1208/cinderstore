require "./spec_helper"

# Writes a table file with the given checksum mode and returns its meta.
def write_table_with_checksums(path : String, entries : Array(Cinderstore::Entry), checksums : Bool, block_size : Int32 = 4096)
  meta = nil
  File.open(path, "w") do |io|
    writer = Cinderstore::SstableWriter.new(io, 7_i64, block_size, 0.01, checksums)
    entries.each do |entry|
      writer.add(entry.key, entry.value, entry.seq, entry.alive)
    end
    meta = writer.finish
  end
  meta.not_nil!
end

# Rewrites a version 2 footer as a version 1 footer without the flags byte.
def downgrade_footer_to_v1(path : String) : Nil
  size = File.size(path)
  File.open(path, "r+") do |f|
    f.pos = size - 49
    v2 = Bytes.new(49)
    f.read_fully(v2)
    footer = Bytes.new(48)
    footer.copy_from(v2[0, 8])
    v2[9, 32].each_with_index { |byte, i| footer[8 + i] = byte }
    footer[40] = 1_u8
    footer[41] = 0_u8
    footer[42] = 0_u8
    footer[43] = 0_u8
    crc = Cinderstore::Util.crc32(footer[0, 44])
    IO::Memory.new(footer[44, 4]).write_bytes(crc, IO::ByteFormat::LittleEndian)
    f.pos = size - 49
    f.write(footer)
    f.truncate(size - 1)
  end
end

def collect_entries(reader : Cinderstore::SstableReader)
  all = [] of Cinderstore::Entry
  reader.block_count.times do |i|
    all.concat(reader.load_block_entries(i))
  end
  all
end

# Returns the file offset of the first block's CRC slot for `entry`.
def block_crc_offset(entry : Cinderstore::Entry) : Int32
  body = IO::Memory.new
  Cinderstore.write_entry(body, entry)
  Cinderstore::Util.varint_len(body.size.to_u64) + body.size
end

describe Cinderstore do
  describe "checksum-free mode" do
    it "defaults to checksums enabled" do
      Cinderstore::DB::Config.new.checksums.should be_true
    end

    it "round trips table entries without checksums" do
      dir = Cinderstore::SpecHelpers.tmp_db_path("fast-table")
      Dir.mkdir_p(dir)
      path = File.join(dir, "000007.sst")
      entries = 200.times.map { |i| Cinderstore::Entry.new("key-%04d" % i, i.to_i64, true, "value-#{i}") }.to_a
      write_table_with_checksums(path, entries, false, 128)
      reader = Cinderstore::SstableReader.new(path, 7_i64, nil)
      collect_entries(reader).should eq(entries)
      reader.close
    end

    it "skips block checksums in a checksum-free table" do
      dir = Cinderstore::SpecHelpers.tmp_db_path("fast-table")
      Dir.mkdir_p(dir)
      path = File.join(dir, "000007.sst")
      entry = Cinderstore::Entry.new("key-0000", 1_i64, true, "value-0")
      write_table_with_checksums(path, [entry], false)

      File.open(path, "r+") do |f|
        f.pos = block_crc_offset(entry)
        byte = f.read_byte.not_nil!
        f.pos = block_crc_offset(entry)
        f.write_byte((byte ^ 0xFF).to_u8)
      end

      reader = Cinderstore::SstableReader.new(path, 7_i64, nil)
      collect_entries(reader).should eq([entry])
      reader.close
    end

    it "detects a corrupt block checksum in a checksummed table" do
      dir = Cinderstore::SpecHelpers.tmp_db_path("fast-table")
      Dir.mkdir_p(dir)
      path = File.join(dir, "000007.sst")
      entry = Cinderstore::Entry.new("key-0000", 1_i64, true, "value-0")
      write_table_with_checksums(path, [entry], true)

      File.open(path, "r+") do |f|
        f.pos = block_crc_offset(entry)
        byte = f.read_byte.not_nil!
        f.pos = block_crc_offset(entry)
        f.write_byte((byte ^ 0xFF).to_u8)
      end

      reader = Cinderstore::SstableReader.new(path, 7_i64, nil)
      expect_raises(Cinderstore::CorruptDataError) do
        reader.load_block_entries(0)
      end
      reader.close
    end

    it "reads a version 1 table from before the mode existed" do
      dir = Cinderstore::SpecHelpers.tmp_db_path("fast-table")
      Dir.mkdir_p(dir)
      path = File.join(dir, "000007.sst")
      entries = 100.times.map { |i| Cinderstore::Entry.new("key-%03d" % i, i.to_i64, true, "value-#{i}") }.to_a
      write_table_with_checksums(path, entries, true, 64)
      downgrade_footer_to_v1(path)

      reader = Cinderstore::SstableReader.new(path, 7_i64, nil)
      collect_entries(reader).should eq(entries)
      reader.close
    end
  end

  describe "checksum-free write ahead log" do
    it "recovers records written without checksums" do
      dir = Cinderstore::SpecHelpers.tmp_db_path("fast-wal")
      Dir.mkdir_p(dir)
      path = File.join(dir, "000001.wal")
      writer = Cinderstore::Wal::Writer.new(path, false, false)
      writer.append(Cinderstore::Entry.new("a", 1_i64, true, "one"))
      writer.append(Cinderstore::Entry.new("b", 2_i64, false, ""))
      writer.close

      mem = Cinderstore::MemTable.new
      Cinderstore::Wal.recover(path, mem, 0_i64).should eq(2_i64)
      mem.get("a").should eq("one")
      mem.get("b").should be_nil
      mem.get_entry("b").not_nil!.alive.should be_false
    end

    it "ignores corruption in a checksum-free log" do
      dir = Cinderstore::SpecHelpers.tmp_db_path("fast-wal")
      Dir.mkdir_p(dir)
      path = File.join(dir, "000001.wal")
      writer = Cinderstore::Wal::Writer.new(path, false, false)
      writer.append(Cinderstore::Entry.new("alpha", 1_i64, true, "1"))
      writer.close

      record = Cinderstore::Wal.encode(Cinderstore::Entry.new("alpha", 1_i64, true, "1"), false)
      crc_offset = Cinderstore::Wal::HEADER_SIZE + record.size - 4
      bytes = File.read(path).to_slice.dup
      bytes[crc_offset] = (bytes[crc_offset] ^ 0xFF).to_u8
      File.open(path, "w") { |f| f.write(bytes) }

      mem = Cinderstore::MemTable.new
      Cinderstore::Wal.recover(path, mem, 0_i64).should eq(1_i64)
      mem.get("alpha").should eq("1")
    end

    it "still verifies a checksummed log that has a header" do
      dir = Cinderstore::SpecHelpers.tmp_db_path("fast-wal")
      Dir.mkdir_p(dir)
      path = File.join(dir, "000001.wal")
      writer = Cinderstore::Wal::Writer.new(path, false, true)
      writer.append(Cinderstore::Entry.new("alpha", 1_i64, true, "1"))
      writer.close

      record = Cinderstore::Wal.encode(Cinderstore::Entry.new("alpha", 1_i64, true, "1"), true)
      crc_offset = Cinderstore::Wal::HEADER_SIZE + record.size - 4
      bytes = File.read(path).to_slice.dup
      bytes[crc_offset] = (bytes[crc_offset] ^ 0xFF).to_u8
      File.open(path, "w") { |f| f.write(bytes) }

      mem = Cinderstore::MemTable.new
      Cinderstore::Wal.recover(path, mem, 0_i64).should eq(0_i64)
      mem.empty?.should be_true
    end

    it "replays an old log without a header" do
      dir = Cinderstore::SpecHelpers.tmp_db_path("fast-wal")
      Dir.mkdir_p(dir)
      path = File.join(dir, "000001.wal")
      File.open(path, "w") do |io|
        io.write(Cinderstore::Wal.encode(Cinderstore::Entry.new("a", 1_i64, true, "one"), true))
        io.write(Cinderstore::Wal.encode(Cinderstore::Entry.new("b", 2_i64, true, "two"), true))
      end

      mem = Cinderstore::MemTable.new
      Cinderstore::Wal.recover(path, mem, 0_i64).should eq(2_i64)
      mem.get("a").should eq("one")
      mem.get("b").should eq("two")
    end
  end

  describe "database in checksum-free mode" do
    it "survives a restart and is read by a default reopen" do
      config = Cinderstore::SpecHelpers.fast_config
      config.checksums = false
      Cinderstore::SpecHelpers.with_db_path("db-fast") do |path|
        db = Cinderstore::DB.new(path, config)
        db.put("a", "1")
        db.put("b", "2")
        db.flush
        db.put("c", "3")
        db.compact
        db.close

        reopened = Cinderstore::DB.new(path)
        reopened.get("a").should eq("1")
        reopened.get("b").should eq("2")
        reopened.get("c").should eq("3")
        reopened.scan.map(&.[0]).should eq(%w[a b c])
        reopened.close
      end
    end

    it "keeps the checksum mode readable across an upgrade" do
      config = Cinderstore::SpecHelpers.fast_config
      config.checksums = false
      Cinderstore::SpecHelpers.with_db_path("db-fast") do |path|
        db = Cinderstore::DB.new(path, config)
        db.put("a", "1")
        db.flush
        db.close

        upgraded = Cinderstore::DB.new(path)
        upgraded.get("a").should eq("1")
        upgraded.put("b", "2")
        upgraded.flush
        upgraded.compact
        upgraded.get("a").should eq("1")
        upgraded.get("b").should eq("2")
        upgraded.close
      end
    end

    it "reports the checksum mode in stats" do
      config = Cinderstore::SpecHelpers.fast_config
      config.checksums = false
      Cinderstore::SpecHelpers.with_db("db-faststats", config) do |db, _path|
        db.stats.checksums.should be_false
      end
      Cinderstore::SpecHelpers.with_db("db-cksstats") do |db, _path|
        db.stats.checksums.should be_true
      end
    end
  end
end
