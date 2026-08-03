require "digest/crc32"

module Cinderstore
  # Small binary helpers shared by every on-disk format.
  module Util
    # Writes an unsigned 64-bit value as a LEB128 varint.
    def self.write_varint(io : IO, value : UInt64) : Nil
      n = value
      loop do
        byte = (n & 0x7F).to_u8
        n >>= 7
        if n == 0
          io.write_byte(byte)
          break
        else
          io.write_byte(byte | 0x80)
        end
      end
    end

    # Reads a LEB128 varint. Raises CorruptDataError on bad input.
    def self.read_varint(io : IO) : UInt64
      result = 0_u64
      shift = 0_u32
      loop do
        byte = io.read_byte
        raise CorruptDataError.new("unexpected end of data") unless byte
        result |= (byte & 0x7F).to_u64 << shift
        return result if (byte & 0x80) == 0
        shift += 7
        raise CorruptDataError.new("varint is too long") if shift >= 64
      end
    end

    # Returns the number of bytes `write_varint` produces for a value.
    def self.varint_len(value : UInt64) : Int32
      n = value
      len = 1
      while n >= 0x80
        n >>= 7
        len += 1
      end
      len
    end

    # FNV-1a 64-bit hash seeded with `salt`.
    #
    # Two different salts produce two independent hash streams. The bloom
    # filter uses them for double hashing.
    def self.fnv1a_64(data : Bytes, salt : UInt64) : UInt64
      hash = 0xcbf29ce484222325_u64 ^ salt
      data.each do |byte|
        hash ^= byte.to_u64
        hash &*= 0x100000001b3_u64
      end
      hash
    end

    # CRC32 over a slice of bytes.
    def self.crc32(data : Bytes) : UInt32
      Digest::CRC32.checksum(data)
    end

    # Zero-padded file stem used by tables and write ahead logs.
    def self.file_stem(id : Int64) : String
      id.to_s.rjust(6, '0')
    end
  end
end
