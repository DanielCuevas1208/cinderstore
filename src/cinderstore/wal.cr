module Cinderstore
  # The write ahead log (WAL).
  #
  # A version-2 log starts with a small header: a magic value and one flag
  # byte. The flag byte says whether the records carry CRC32 checksums and
  # whether each record starts with a kind byte.
  #
  # A version-3 record starts with a kind byte. Kind zero is a single
  # entry. Kind one is a batch of entries. Both share one CRC32, so a torn
  # batch is dropped whole during recovery. Version-1 and version-2 logs
  # have no kind byte. Their records always hold one entry and always carry
  # checksums. Recovery reads the header to learn how to parse the file.
  #
  # With checksums enabled the database fsyncs once per commit group. A
  # torn write at the tail is truncated during recovery.
  class Wal
    # First bytes of a version-2 log.
    HEADER_MAGIC = 0x31535743_u32
    # Total header bytes: magic value plus flag byte.
    HEADER_SIZE = 5_i64
    # Flag that says the records carry CRC32 checksums.
    FLAG_CHECKSUMS = 1_u8
    # Flag that says each record starts with a kind byte.
    FLAG_KIND = 2_u8

    # Record kind for a single entry.
    KIND_ENTRY = 0_u8
    # Record kind for a batch of entries.
    KIND_BATCH = 1_u8

    # Describes how the records in one log are framed.
    private record Format, checksums : Bool, kind : Bool

    # Serializes an entry into a version-1 framed record.
    #
    # A version-1 record holds a varint length, the entry body, and a CRC32
    # over the body. This method exists so tests can build legacy files.
    def self.encode(entry : Entry, checksums : Bool = true) : Bytes
      body = IO::Memory.new
      Cinderstore.write_entry(body, entry)
      payload = body.to_slice
      framed = IO::Memory.new
      Util.write_varint(framed, payload.size.to_u64)
      framed.write(payload)
      framed.write_bytes(Util.crc32(payload), IO::ByteFormat::LittleEndian) if checksums
      framed.to_slice
    end

    # Serializes a single entry into a version-3 record.
    def self.encode_entry(entry : Entry, checksums : Bool = true) : Bytes
      body = IO::Memory.new
      Cinderstore.write_entry(body, entry)
      encode_payload(KIND_ENTRY, body.to_slice, checksums)
    end

    # Serializes a batch of entries into one version-3 record.
    #
    # The body holds a varint count followed by that many serialized
    # entries. The whole record carries one CRC32, so recovery either
    # applies every entry or drops the record.
    def self.encode_batch(entries : Array(Entry), checksums : Bool = true) : Bytes
      body = IO::Memory.new
      Util.write_varint(body, entries.size.to_u64)
      entries.each { |entry| Cinderstore.write_entry(body, entry) }
      encode_payload(KIND_BATCH, body.to_slice, checksums)
    end

    # Writes the version-2 header to `io`.
    def self.write_header(io : IO, checksums : Bool, kind : Bool = true) : Nil
      io.write_bytes(HEADER_MAGIC, IO::ByteFormat::LittleEndian)
      flags = (checksums ? FLAG_CHECKSUMS : 0_u8) | (kind ? FLAG_KIND : 0_u8)
      io.write_byte(flags)
    end

    # Frames a kind byte, a payload, and an optional CRC32 over both.
    private def self.encode_payload(kind : UInt8, payload : Bytes, checksums : Bool) : Bytes
      framed = IO::Memory.new
      Util.write_varint(framed, (payload.size + 1).to_u64)
      framed.write_byte(kind)
      framed.write(payload)
      if checksums
        crc_source = IO::Memory.new
        crc_source.write_byte(kind)
        crc_source.write(payload)
        framed.write_bytes(Util.crc32(crc_source.to_slice), IO::ByteFormat::LittleEndian)
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
        format = read_format(io)
        loop do
          break if io.pos >= io.size
          begin
            body_len = Util.read_varint(io).to_i
            if format.kind
              kind = io.read_byte.not_nil!
              body = Bytes.new(body_len - 1)
              io.read_fully(body)
              verify_checksum(io, kind, body) if format.checksums
              max_seq = apply_kind(kind, body, mem, max_seq)
            else
              body = Bytes.new(body_len)
              io.read_fully(body)
              if format.checksums
                stored_crc = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
                actual_crc = Util.crc32(body)
                raise CorruptDataError.new("wal checksum mismatch") unless stored_crc == actual_crc
              end
              max_seq = apply_entry(Cinderstore.read_entry(IO::Memory.new(body)), mem, max_seq)
            end
          rescue ex : IO::EOFError
            break
          rescue ex : Error
            break
          end
        end
      end
      max_seq
    end

    # Detects the record framing of a log and leaves `io` at the first
    # record. A version-2 header sets the mode from its flag byte. A legacy
    # version-1 log has no header, so its records are entries with
    # checksums and no kind byte.
    private def self.read_format(io : IO) : Format
      return Format.new(true, false) if io.size < HEADER_SIZE
      magic = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      if magic == HEADER_MAGIC
        if flags = io.read_byte
          return Format.new((flags & FLAG_CHECKSUMS) != 0, (flags & FLAG_KIND) != 0)
        end
        # The header is torn after the magic. Nothing is recoverable.
        io.pos = io.size
        return Format.new(true, false)
      end
      io.pos = 0
      Format.new(true, false)
    end

    # Verifies the CRC32 over a kind byte and its body.
    private def self.verify_checksum(io : IO, kind : UInt8, body : Bytes) : Nil
      crc_source = IO::Memory.new
      crc_source.write_byte(kind)
      crc_source.write(body)
      stored_crc = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      actual_crc = Util.crc32(crc_source.to_slice)
      raise CorruptDataError.new("wal checksum mismatch") unless stored_crc == actual_crc
    end

    # Applies one entry to `mem` and returns the higher sequence number.
    private def self.apply_entry(entry : Entry, mem : MemTable, max_seq : Int64) : Int64
      if entry.alive
        mem.put(entry.key, entry.value, entry.seq)
      else
        mem.delete(entry.key, entry.seq)
      end
      entry.seq > max_seq ? entry.seq : max_seq
    end

    # Applies a kind-byte record to `mem` and returns the higher sequence
    # number. A batch applies every entry it holds.
    private def self.apply_kind(kind : UInt8, body : Bytes, mem : MemTable, max_seq : Int64) : Int64
      case kind
      when KIND_ENTRY
        apply_entry(Cinderstore.read_entry(IO::Memory.new(body)), mem, max_seq)
      when KIND_BATCH
        io = IO::Memory.new(body)
        count = Util.read_varint(io).to_i
        seq = max_seq
        count.times do
          seq = apply_entry(Cinderstore.read_entry(io), mem, seq)
        end
        seq
      else
        raise CorruptDataError.new("unknown wal record kind")
      end
    end

    # Appends framed records to a WAL file.
    class Writer
      getter path : String
      getter size : Int64

      # Opens the log and writes a version-2 header on a fresh file.
      def initialize(@path : String, @sync_each_write : Bool = true, @checksums : Bool = true,
                     @kind : Bool = true)
        @file = File.open(@path, "a+")
        @closed = false
        @size = @file.size
        if @size == 0
          Wal.write_header(@file, @checksums, @kind)
          @file.flush
          @file.fsync if @sync_each_write
          @size = HEADER_SIZE
        end
      end

      # Appends one entry to the file and flushes the userspace buffer.
      # The database decides when the buffer becomes durable.
      def append(entry : Entry) : Nil
        record = Wal.encode_entry(entry, @checksums)
        @file.write(record)
        @file.flush
        @size += record.size
      end

      # Appends a batch of entries as one record.
      def append_batch(entries : Array(Entry)) : Nil
        record = Wal.encode_batch(entries, @checksums)
        @file.write(record)
        @file.flush
        @size += record.size
      end

      # Forces the buffered records to the disk. Called once per commit
      # group, and on close.
      def sync : Nil
        return if @closed
        @file.flush
        @file.fsync
      end

      def close : Nil
        return if @closed
        @closed = true
        @file.flush
        @file.fsync
        @file.close
      end
    end
  end
end
