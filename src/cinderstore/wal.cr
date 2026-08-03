module Cinderstore
  # The write ahead log (WAL).
  #
  # The WAL frames each entry with a length, a payload, and a CRC32. We
  # fsync after every append when durability is enabled. A torn write at
  # the tail is truncated during recovery.
  #
  # A WAL can skip checksums. Such a file starts with a header that records
  # the mode. Recovery reads the header and skips verification for records
  # in that file. Older WALs without a header always carried checksums.
  class Wal
    # Version 2 header magic. The leading zero byte can never begin a v1
    # record, because every v1 record starts with a non-zero length varint.
    HEADER_MAGIC   = Bytes[0x00_u8, 0x43_u8, 0x49_u8, 0x4E_u8]
    HEADER_SIZE    = (HEADER_MAGIC.size + 1).to_i64
    FLAG_CHECKSUMS = 0x01_u8

    # Returns the version 2 header for a writer.
    def self.header(checksums : Bool) : Bytes
      Bytes[HEADER_MAGIC[0], HEADER_MAGIC[1], HEADER_MAGIC[2], HEADER_MAGIC[3],
        checksums ? FLAG_CHECKSUMS : 0_u8]
    end

    # Serializes an entry into a framed record.
    def self.encode(entry : Entry, checksums : Bool = true) : Bytes
      body = IO::Memory.new
      Cinderstore.write_entry(body, entry)
      payload = body.to_slice
      framed = IO::Memory.new
      Util.write_varint(framed, payload.size.to_u64)
      framed.write(payload)
      if checksums
        framed.write_bytes(Util.crc32(payload), IO::ByteFormat::LittleEndian)
      else
        framed.write_bytes(0_u32, IO::ByteFormat::LittleEndian)
      end
      framed.to_slice
    end

    # Applies all intact records in `path` to `mem`.
    #
    # Returns the largest sequence number seen, or `base_seq`. A partial
    # or corrupt trailing record stops the replay. Everything before it is
    # preserved.
    def self.recover(path : String, mem : MemTable, base_seq : Int64) : Int64
      max_seq = base_seq
      return max_seq unless File.exists?(path)

      File.open(path, "r") do |io|
        checksums = read_header(io)
        loop do
          break if io.pos >= io.size
          begin
            body_len = Util.read_varint(io).to_i
            body = Bytes.new(body_len)
            io.read_fully(body)
            if checksums
              stored_crc = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
              actual_crc = Util.crc32(body)
              raise CorruptDataError.new("wal checksum mismatch") unless stored_crc == actual_crc
            else
              io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            end
            entry = Cinderstore.read_entry(IO::Memory.new(body))
            if entry.alive
              mem.put(entry.key, entry.value, entry.seq)
            else
              mem.delete(entry.key, entry.seq)
            end
            max_seq = entry.seq if entry.seq > max_seq
          rescue ex : IO::EOFError
            break
          rescue ex : Error
            break
          end
        end
      end
      max_seq
    end

    # Consumes a version 2 header when present. Returns whether the records
    # that follow carry checksums. Files without a header are v1 and always
    # carry checksums.
    private def self.read_header(io : IO) : Bool
      first = io.read_byte
      if first == HEADER_MAGIC[0] && io.size >= HEADER_SIZE
        rest = Bytes.new(HEADER_MAGIC.size - 1)
        io.read_fully(rest)
        if rest[0] == HEADER_MAGIC[1] && rest[1] == HEADER_MAGIC[2] && rest[2] == HEADER_MAGIC[3]
          flags = io.read_byte.not_nil!
          return (flags & FLAG_CHECKSUMS) != 0
        end
      end
      io.pos = 0
      true
    end

    # Appends framed records to a WAL file.
    class Writer
      getter path : String
      getter size : Int64
      getter checksums : Bool

      def initialize(@path : String, @sync_each_write : Bool = true, @checksums : Bool = true)
        @file = File.open(@path, "a+")
        @size = @file.size
        write_header if @size == 0
      end

      def append(entry : Entry) : Nil
        record = Wal.encode(entry, @checksums)
        @file.write(record)
        @file.flush
        @file.fsync if @sync_each_write
        @size += record.size
      end

      def close : Nil
        @file.fsync
        @file.close
      end

      private def write_header : Nil
        @file.write(Wal.header(@checksums))
        @file.flush
        @size = Wal::HEADER_SIZE
      end
    end
  end
end
