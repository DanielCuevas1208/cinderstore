require "./spec_helper"

def write_table(path : String, entries : Array(Cinderstore::Entry), block_size : Int32 = 4096)
  meta = nil
  File.open(path, "w") do |io|
    writer = Cinderstore::SstableWriter.new(io, 7_i64, block_size, 0.01)
    entries.each do |entry|
      writer.add(entry.key, entry.value, entry.seq, entry.alive)
    end
    meta = writer.finish
  end
  meta.not_nil!
end

def read_all(reader : Cinderstore::SstableReader)
  all = [] of Cinderstore::Entry
  reader.block_count.times do |i|
    all.concat(reader.load_block_entries(i))
  end
  all
end

# Rewrites a version-2 table file into the version-1 layout.
#
# The data blocks, index, and bloom filter are identical between the two
# versions. Only the footer differs. The version-1 footer drops the flag
# byte and the reserved bytes, and it carries its own CRC32.
def rewrite_as_legacy_v1(path : String) : Nil
  bytes = File.read(path).to_slice
  footer_start = bytes.size - Cinderstore::SstableWriter::FOOTER_SIZE
  prefix = bytes[0, footer_start]
  footer = bytes[footer_start, 44].dup

  # Patch the version field from 2 to 1. It sits 40 bytes into the footer.
  version_io = IO::Memory.new(footer)
  version_io.pos = 40
  version_io.write_bytes(1_u32, IO::ByteFormat::LittleEndian)

  # A version-1 footer is the fixed fields plus a CRC32.
  legacy_footer = IO::Memory.new
  legacy_footer.write(footer)
  legacy_footer.write_bytes(Cinderstore::Util.crc32(footer), IO::ByteFormat::LittleEndian)

  rebuilt = IO::Memory.new
  rebuilt.write(prefix)
  rebuilt.write(legacy_footer.to_slice)
  File.write(path, rebuilt.to_slice)
end

describe Cinderstore::SstableWriter do
  it "round trips entries through a reader" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("table")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000007.sst")
    entries = 300.times.map { |i| Cinderstore::Entry.new("key-%04d" % i, i.to_i64, true, "value-#{i}") }.to_a
    meta = write_table(path, entries)
    meta.count.should eq(300)
    meta.first.should eq("key-0000")
    meta.last.should eq("key-0299")

    reader = Cinderstore::SstableReader.new(path, 7_i64, nil)
    read_all(reader).should eq(entries)
    reader.close
  end

  it "round trips tombstones" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("table")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000007.sst")
    entries = [
      Cinderstore::Entry.new("a", 1_i64, true, "v"),
      Cinderstore::Entry.new("b", 2_i64, false, ""),
    ]
    write_table(path, entries)
    reader = Cinderstore::SstableReader.new(path, 7_i64, nil)
    decoded = read_all(reader)
    decoded[1].alive.should be_false
    reader.close
  end

  it "round trips entries without checksums" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("table")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000007.sst")
    entries = 300.times.map { |i| Cinderstore::Entry.new("key-%04d" % i, i.to_i64, true, "value-#{i}") }.to_a
    File.open(path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 7_i64, 4096, 0.01, false)
      entries.each do |entry|
        writer.add(entry.key, entry.value, entry.seq, entry.alive)
      end
      writer.finish
    end

    reader = Cinderstore::SstableReader.new(path, 7_i64, nil)
    read_all(reader).should eq(entries)
    reader.close
  end

  it "does not verify data blocks that carry no checksums" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("table")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000007.sst")
    entries = 50.times.map { |i| Cinderstore::Entry.new("k%03d" % i, i.to_i64, true, "v") }.to_a
    File.open(path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 7_i64, 64, 0.01, false)
      entries.each { |entry| writer.add(entry.key, entry.value, entry.seq, entry.alive) }
      writer.finish
    end

    # Corrupt the value byte of the first entry in the first block. The
    # value byte of a four-byte key sits eight bytes into the payload.
    File.open(path, "r+") do |f|
      length = Cinderstore::Util.read_varint(f).to_i
      target = f.pos + 8
      f.pos = target
      byte = f.read_byte.not_nil!
      f.pos = target
      f.write_byte((byte ^ 0xFF).to_u8)
    end

    reader = Cinderstore::SstableReader.new(path, 7_i64, nil)
    decoded = read_all(reader)
    decoded.size.should eq(entries.size)
    decoded.first.value.should_not eq("v")
    reader.close
  end

  it "reads a legacy version-1 table" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("table")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000007.sst")
    entries = [
      Cinderstore::Entry.new("a", 1_i64, true, "1"),
      Cinderstore::Entry.new("b", 2_i64, true, "2"),
      Cinderstore::Entry.new("c", 3_i64, true, "3"),
    ]
    File.open(path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 7_i64, 256, 0.01, true)
      entries.each { |entry| writer.add(entry.key, entry.value, entry.seq, entry.alive) }
      writer.finish
    end
    rewrite_as_legacy_v1(path)

    reader = Cinderstore::SstableReader.new(path, 7_i64, nil)
    read_all(reader).should eq(entries)
    reader.close
  end

  it "splits data into multiple blocks" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("table")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000007.sst")
    entries = 500.times.map { |i| Cinderstore::Entry.new("key-%04d" % i, i.to_i64, true, "value-#{i}") }.to_a
    meta = write_table(path, entries, 128)
    reader = Cinderstore::SstableReader.new(path, 7_i64, nil)
    reader.block_count.should be > 1
    read_all(reader).should eq(entries)
    reader.close
  end

  it "preserves the caller-provided key order across blocks" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("table")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000007.sst")
    entries = 200.times.map { |i| Cinderstore::Entry.new("k%05d" % i, i.to_i64, true, "v") }.to_a
    write_table(path, entries, 64)
    reader = Cinderstore::SstableReader.new(path, 7_i64, nil)
    read_all(reader).should eq(entries)
    reader.close
  end

  it "rejects finishing an empty table" do
    io = IO::Memory.new
    writer = Cinderstore::SstableWriter.new(io, 1_i64)
    expect_raises(Cinderstore::Error) { writer.finish }
  end

  it "detects a corrupt footer" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("table")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000007.sst")
    entries = [Cinderstore::Entry.new("a", 1_i64, true, "v")]
    write_table(path, entries)

    size = File.size(path)
    File.open(path, "r+") do |f|
      f.pos = size - 1
      byte = f.read_byte.not_nil!
      f.pos = size - 1
      f.write_byte((byte ^ 0xFF).to_u8)
    end

    expect_raises(Cinderstore::CorruptDataError) do
      Cinderstore::SstableReader.new(path, 7_i64, nil)
    end
  end

  it "detects a corrupt data block" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("table")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000007.sst")
    entries = 100.times.map { |i| Cinderstore::Entry.new("key-%03d" % i, i.to_i64, true, "value-#{i}") }.to_a
    write_table(path, entries, 64)

    File.open(path, "r+") do |f|
      f.pos = 0
      byte = f.read_byte.not_nil!
      f.pos = 0
      f.write_byte((byte ^ 0xFF).to_u8)
    end

    reader = Cinderstore::SstableReader.new(path, 7_i64, nil)
    expect_raises(Cinderstore::CorruptDataError) do
      reader.load_block_entries(0)
    end
  end
end
