module Cinderstore
  # The write ahead log (WAL).
  #
  # The WAL frames each entry with a length and a payload. A CRC32 guard
  # follows each payload when checksums are enabled. We fsync after every
  # append when durability is enabled. A torn write at the tail is
  # truncated during recovery.
  #
  # Every WAL starts with a header that records its format. The header
  # makes each file self describing, so a database can mix formats after a
  # configuration change.
  class Wal
    MAGIC = Bytes[0x43, 0x49, 0x4E, 0x44, 0x57, 0x41, 0x4C, 0x00]

    # Format version that writes a CRC32 guard per record.
    FORMAT_CHECKSUMMED = 1_u8
    # Format version that writes no CRC32 guards.
    FORMAT_FAST = 2_u8

    # Header size: magic plus the format byte.
    HEADER_SIZE = 9_i64

    # Upper bound for one record. Recovery uses it to reject garbage
    # lengths before allocating a buffer.
    MAX_RECORD_BYTES = 8 * 1024 * 1024

    # Serializes an entry into a framed record.
    #
    # A CRC32 guard follows the payload when `checksums` is true.
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
    # preserved. The format comes from the file header, so the caller does
    # not need to know how the log was written.
    def self.recover(path : String, mem : MemTable, base_seq : Int64) : Int64
      max_seq = base_seq
      return max_seq unless File.exists?(path)

      File.open(path, "r") do |io|
        format, start = detect_format(io)
        io.pos = start
        loop do
          break if io.pos >= io.size
          begin
            body_len = Util.read_varint(io).to_i
            raise CorruptDataError.new("wal record is too large") if body_len > MAX_RECORD_BYTES
            body = Bytes.new(body_len)
            io.read_fully(body)
            if format == FORMAT_CHECKSUMMED
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

    # Returns the format of `io` and the offset where records begin.
    #
    # Logs written before the header existed have no magic. They use the
    # checksummed format, which keeps old files readable.
    def self.detect_format(io : IO) : Tuple(UInt8, Int64)
      return {FORMAT_CHECKSUMMED, 0_i64} if io.size < HEADER_SIZE
      io.pos = 0
      head = Bytes.new(MAGIC.size)
      io.read_fully(head)
      return {FORMAT_CHECKSUMMED, 0_i64} unless head == MAGIC
      {io.read_byte.not_nil!, HEADER_SIZE}
    end

    # Appends framed records to a WAL file.
    class Writer
      getter path : String
      getter size : Int64

      def initialize(@path : String, @sync_each_write : Bool = true, checksums : Bool = true)
        @file = File.open(@path, "a+")
        @size = @file.size
        @checksums = checksums
        if @size == 0
          write_header
        else
          # An existing log keeps its own format. New records must match
          # the records already on disk so recovery can read them together.
          @checksums = Wal.detect_format(@file).first == FORMAT_CHECKSUMMED
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

      private def write_header : Nil
        io = IO::Memory.new
        io.write(MAGIC)
        io.write_byte(@checksums ? FORMAT_CHECKSUMMED : FORMAT_FAST)
        @file.write(io.to_slice)
        @file.flush
        @size = HEADER_SIZE
      end
    end
  end
end
