module Cinderstore
  # The write ahead log (WAL).
  #
  # The WAL frames each entry with a length, a payload, and a CRC32. We
  # fsync after every append when durability is enabled. A torn write at
  # the tail is truncated during recovery.
  #
  # Checksums are optional. When they are disabled, every record carries a
  # zero checksum and recovery skips verification. A stored zero is treated
  # as "no checksum", so a log written in one mode replays in the other.
  class Wal
    # Serializes an entry into a framed record.
    #
    # When `checksums` is false, the checksum field is written as zero and
    # never computed.
    def self.encode(entry : Entry, checksums : Bool = true) : Bytes
      body = IO::Memory.new
      Cinderstore.write_entry(body, entry)
      payload = body.to_slice
      framed = IO::Memory.new
      Util.write_varint(framed, payload.size.to_u64)
      framed.write(payload)
      crc = checksums ? Util.crc32(payload) : 0_u32
      framed.write_bytes(crc, IO::ByteFormat::LittleEndian)
      framed.to_slice
    end

    # Applies all intact records in `path` to `mem`.
    #
    # Returns the largest sequence number seen, or `base_seq`. A partial
    # or corrupt trailing record stops the replay. Everything before it is
    # preserved.
    #
    # When `checksums` is false, or a record carries a zero checksum,
    # verification is skipped. The record layout is still parsed.
    def self.recover(path : String, mem : MemTable, base_seq : Int64, checksums : Bool = true) : Int64
      max_seq = base_seq
      return max_seq unless File.exists?(path)

      File.open(path, "r") do |io|
        loop do
          break if io.pos >= io.size
          begin
            body_len = Util.read_varint(io).to_i
            body = Bytes.new(body_len)
            io.read_fully(body)
            stored_crc = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
            if checksums && stored_crc != 0_u32
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

    # Appends framed records to a WAL file.
    class Writer
      getter path : String
      getter size : Int64

      def initialize(@path : String, @sync_each_write : Bool = true, @checksums : Bool = true)
        @file = File.open(@path, "a+")
        @size = @file.size
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
