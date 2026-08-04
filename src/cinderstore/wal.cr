module Cinderstore
  # The write ahead log (WAL).
  #
  # A version-2 log starts with a small header: a magic value and one flag
  # byte. The flag byte says whether the records carry CRC32 checksums.
  # Version-1 logs have no header. Their records always carry checksums.
  # Recovery reads the header to learn how to parse the file.
  #
  # With checksums enabled we fsync after every append when durability is
  # enabled. A torn write at the tail is truncated during recovery.
  class Wal
    # First bytes of a version-2 log.
    HEADER_MAGIC = 0x31535743_u32
    # Total header bytes: magic value plus flag byte.
    HEADER_SIZE = 5_i64
    # Flag that says the records carry CRC32 checksums.
    FLAG_CHECKSUMS = 1_u8

    # Serializes an entry into a framed record.
    #
    # A record holds a varint length, the entry body, and an optional CRC32
    # when `checksums` is true.
    def self.encode(entry : Entry, checksums : Bool = true) : Bytes
      body = IO::Memory.new
      Cinderstore.write_entry(body, entry)
      payload = body.to_slice
      framed = IO::Memory.new
      Util.write_varint(framed, payload.size.to_u64)
      framed.write(payload)
      if checksums
        framed.write_bytes(Util.crc32(payload), IO::ByteFormat::LittleEndian)
      end
      framed.to_slice
    end

    # Writes the version-2 header to `io`.
    def self.write_header(io : IO, checksums : Bool) : Nil
      io.write_bytes(HEADER_MAGIC, IO::ByteFormat::LittleEndian)
      io.write_byte(checksums ? FLAG_CHECKSUMS : 0_u8)
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
        checksums = read_mode(io)
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

    # Detects the record mode of a log and leaves `io` at the first record.
    #
    # Returns true when records carry checksums. A version-2 header sets
    # the mode from its flag byte. A legacy version-1 log has no header and
    # always carries checksums.
    private def self.read_mode(io : IO) : Bool
      return true if io.size < HEADER_SIZE
      magic = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      if magic == HEADER_MAGIC
        if flags = io.read_byte
          return (flags & FLAG_CHECKSUMS) != 0
        end
        # The header is torn after the magic. Nothing is recoverable.
        io.pos = io.size
        return true
      end
      io.pos = 0
      true
    end

    # Appends framed records to a WAL file.
    class Writer
      getter path : String
      getter size : Int64

      # Opens the log and writes a version-2 header on a fresh file.
      def initialize(@path : String, @sync_each_write : Bool = true, @checksums : Bool = true)
        @file = File.open(@path, "a+")
        @size = @file.size
        if @size == 0
          Wal.write_header(@file, @checksums)
          @file.flush
          @file.fsync if @sync_each_write
          @size = HEADER_SIZE
        end
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
    end
  end
end
