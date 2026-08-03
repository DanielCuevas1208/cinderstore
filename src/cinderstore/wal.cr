module Cinderstore
  # The write ahead log (WAL).
  #
  # Every WAL starts with a nine byte header. The header holds a magic value
  # and one flag byte. The flag byte marks whether the records carry CRC32
  # checksums. The writer records its mode in the header. Recovery reads the
  # header first, so it parses each file correctly even when the database
  # configuration changes between restarts.
  #
  # With checksums enabled, each record is a length, a payload, and a CRC32.
  # A torn write at the tail is detected and truncated during recovery. With
  # checksums disabled, each record is only a length and a payload. Recovery
  # then stops at the first malformed tail. This mode trades integrity
  # checking for speed.
  #
  # Files without a header are treated as legacy checksummed logs. This keeps
  # databases written by release 0.3 readable.
  class Wal
    # Magic value "CINDERWA" written as little endian bytes.
    MAGIC = 0x43494E4445525741_u64
    # Flag bit that marks checksummed records.
    FLAG_CHECKSUMS = 1_u8
    # Header size in bytes.
    HEADER_SIZE = 9

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
        checksums = detect_checksums(io)
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

    # Returns true when the log records carry checksums.
    #
    # Reads the header when present. A file without a header is a legacy
    # checksummed log. A headerless empty file carries no records, so either
    # mode is safe.
    private def self.detect_checksums(io : IO) : Bool
      return true if io.size < HEADER_SIZE
      header = Bytes.new(HEADER_SIZE)
      io.read_fully(header)
      magic = IO::Memory.new(header[0, 8]).read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      unless magic == MAGIC
        # A legacy log has no header. Rewind so the records parse from
        # the start of the file.
        io.pos = 0
        return true
      end
      (header[8] & FLAG_CHECKSUMS) != 0
    end

    # Appends framed records to a fresh WAL file.
    class Writer
      getter path : String
      getter size : Int64

      def initialize(@path : String, @sync_each_write : Bool = true, @checksums : Bool = true)
        # A WAL is always created fresh. It is replaced after every flush.
        @file = File.open(@path, "w+")
        @size = 0_i64
        header = IO::Memory.new
        header.write_bytes(MAGIC, IO::ByteFormat::LittleEndian)
        header.write_byte(@checksums ? FLAG_CHECKSUMS : 0_u8)
        @file.write(header.to_slice)
        @size += HEADER_SIZE
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
