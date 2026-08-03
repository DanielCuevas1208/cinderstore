require "./spec_helper"

describe Cinderstore::Util do
  it "round trips varints" do
    [0_u64, 1_u64, 127_u64, 128_u64, 300_u64, 16_383_u64, 16_384_u64, 1_000_000_u64].each do |value|
      io = IO::Memory.new
      Cinderstore::Util.write_varint(io, value)
      io.pos = 0
      Cinderstore::Util.read_varint(io).should eq(value)
    end
  end

  it "computes varint length" do
    Cinderstore::Util.varint_len(0_u64).should eq(1)
    Cinderstore::Util.varint_len(127_u64).should eq(1)
    Cinderstore::Util.varint_len(128_u64).should eq(2)
    Cinderstore::Util.varint_len(16_383_u64).should eq(2)
  end

  it "rejects a varint that never terminates" do
    io = IO::Memory.new(Bytes.new(12, 0x80_u8))
    expect_raises(Cinderstore::CorruptDataError) do
      Cinderstore::Util.read_varint(io)
    end
  end

  it "hashes deterministically" do
    data = "ember-tray".to_slice
    Cinderstore::Util.fnv1a_64(data, 1_u64).should eq(Cinderstore::Util.fnv1a_64(data, 1_u64))
    Cinderstore::Util.fnv1a_64(data, 1_u64).should_not eq(Cinderstore::Util.fnv1a_64(data, 2_u64))
  end

  it "formats file stems with zero padding" do
    Cinderstore::Util.file_stem(1_i64).should eq("000001")
    Cinderstore::Util.file_stem(999_999_i64).should eq("999999")
  end

  it "round trips entries" do
    entry = Cinderstore::Entry.new("a-key", 7_i64, true, "a value")
    io = IO::Memory.new
    Cinderstore.write_entry(io, entry)
    io.pos = 0
    decoded = Cinderstore.read_entry(io)
    decoded.key.should eq("a-key")
    decoded.seq.should eq(7_i64)
    decoded.alive.should be_true
    decoded.value.should eq("a value")
  end

  it "round trips tombstone entries" do
    entry = Cinderstore::Entry.new("gone", 3_i64, false, "")
    io = IO::Memory.new
    Cinderstore.write_entry(io, entry)
    io.pos = 0
    decoded = Cinderstore.read_entry(io)
    decoded.alive.should be_false
    decoded.value.should eq("")
  end

  it "decodes a batch of entries" do
    io = IO::Memory.new
    Cinderstore.write_entry(io, Cinderstore::Entry.new("a", 1_i64, true, "1"))
    Cinderstore.write_entry(io, Cinderstore::Entry.new("b", 2_i64, false, ""))
    decoded = Cinderstore.decode_entries(io.to_slice)
    decoded.size.should eq(2)
    decoded[0].key.should eq("a")
    decoded[1].alive.should be_false
  end
end
