module Cinderstore
  # A single key/value record with its ordering and liveness metadata.
  #
  # Each entry carries a sequence number that is unique per database write.
  # A higher sequence number means a newer write. A tombstone is an entry
  # with `alive == false`. Tombstones hide older values for the same key.
  struct Entry
    getter key : String
    getter seq : Int64
    getter alive : Bool
    getter value : String

    def initialize(@key : String, @seq : Int64, @alive : Bool, @value : String)
    end
  end

  # Serializes an entry into a compact binary form.
  #
  # Layout: key length, key bytes, sequence, liveness byte, value length,
  # value bytes. All lengths are varints.
  def self.write_entry(io : IO, entry : Entry) : Nil
    Util.write_varint(io, entry.key.bytesize.to_u64)
    io.write(entry.key.to_slice)
    Util.write_varint(io, entry.seq.to_u64)
    io.write_byte(entry.alive ? 1_u8 : 0_u8)
    Util.write_varint(io, entry.value.bytesize.to_u64)
    io.write(entry.value.to_slice)
  end

  # Reads an entry that `write_entry` wrote.
  def self.read_entry(io : IO) : Entry
    key_len = Util.read_varint(io).to_i
    key = io.read_string(key_len)
    seq = Util.read_varint(io).to_i64
    alive = io.read_byte == 1_u8
    value_len = Util.read_varint(io).to_i
    value = io.read_string(value_len)
    Entry.new(key, seq, alive, value)
  end

  # Decodes all entries in a slice of serialized entry bytes.
  def self.decode_entries(data : Bytes) : Array(Entry)
    io = IO::Memory.new(data)
    entries = [] of Entry
    while io.pos < io.size
      entries << read_entry(io)
    end
    entries
  end
end
