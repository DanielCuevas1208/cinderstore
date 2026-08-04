module Cinderstore
  # Describes a sorted table on disk. Stored in the manifest.
  struct TableMeta
    getter id : Int64
    getter first : String
    getter last : String
    getter count : Int64

    def initialize(@id : Int64, @first : String, @last : String, @count : Int64)
    end
  end

  # One entry of the in-file block index.
  struct BlockIndexEntry
    getter first_key : String
    getter offset : UInt64
    getter length : UInt64

    def initialize(@first_key : String, @offset : UInt64, @length : UInt64)
    end
  end

  # A sorted string table (SSTable).
  #
  # File layout:
  #
  #   [data blocks]
  #   [block index]
  #   [bloom filter]
  #   [footer]
  #
  # A data block holds the block length, a batch of serialized entries,
  # and a CRC32. The block index maps the first key of each block to its
  # file offset and total length. The bloom filter lets a reader skip a
  # table that cannot contain a key. The footer stores offsets, a format
  # version, and a CRC32 over the entire footer.
  #
  # Fast tables use version two and skip every CRC32. The footer keeps its
  # fixed size, so the reader can find the version before it decides how
  # to verify the rest of the file.
  class SstableWriter
    MAGIC = 0x43494E4445525F31_u64
    # Format version that writes a CRC32 per block and on the footer.
    VERSION_CHECKSUMMED = 1_u32
    # Format version that writes no CRC32 guards.
    VERSION_FAST = 2_u32
    FOOTER_SIZE  =    48

    @io : IO
    @id : Int64
    @block_size : Int32
    @fpp : Float64
    @checksums : Bool
    @pending : IO::Memory
    @pending_keys : Array(String)
    @keys : Array(String)
    @index : Array(BlockIndexEntry)
    @count : Int64 = 0_i64
    @first : String?
    @last : String?

    def initialize(io : IO, @id : Int64, @block_size : Int32 = 4096, @fpp : Float64 = 0.01,
                   @checksums : Bool = true)
      @io = io
      @pending = IO::Memory.new
      @pending_keys = [] of String
      @keys = [] of String
      @index = [] of BlockIndexEntry
      @first = nil
      @last = nil
    end

    # Appends one entry to the current block. Keys must arrive in
    # ascending order with no duplicates.
    def add(key : String, value : String, seq : Int64, alive : Bool) : Nil
      entry = Entry.new(key, seq, alive, value)
      Cinderstore.write_entry(@pending, entry)
      @pending_keys << key
      @keys << key
      @first = key if @first.nil?
      @last = key
      @count += 1
      flush_block if @pending.size >= @block_size
    end

    # Writes the index, bloom filter, and footer. Returns the table meta.
    def finish : TableMeta
      raise Error.new("cannot finish an empty table") if @count == 0
      flush_block if @pending.size > 0

      index_offset = @io.pos
      Util.write_varint(@io, @index.size.to_u64)
      @index.each do |entry|
        Util.write_varint(@io, entry.first_key.bytesize.to_u64)
        @io.write(entry.first_key.to_slice)
        Util.write_varint(@io, entry.offset)
        Util.write_varint(@io, entry.length)
      end
      index_length = @io.pos - index_offset

      bloom = BloomFilter.build(@keys, @fpp)
      bloom_offset = @io.pos
      bloom.serialize(@io)
      bloom_length = @io.pos - bloom_offset

      footer = IO::Memory.new
      footer.write_bytes(MAGIC, IO::ByteFormat::LittleEndian)
      footer.write_bytes(index_offset.to_u64, IO::ByteFormat::LittleEndian)
      footer.write_bytes(index_length.to_u64, IO::ByteFormat::LittleEndian)
      footer.write_bytes(bloom_offset.to_u64, IO::ByteFormat::LittleEndian)
      footer.write_bytes(bloom_length.to_u64, IO::ByteFormat::LittleEndian)
      footer.write_bytes(@checksums ? VERSION_CHECKSUMMED : VERSION_FAST, IO::ByteFormat::LittleEndian)
      footer_bytes = footer.to_slice
      @io.write(footer_bytes)
      if @checksums
        @io.write_bytes(Util.crc32(footer_bytes), IO::ByteFormat::LittleEndian)
      else
        @io.write(Bytes.new(4, 0_u8))
      end
      @io.flush

      TableMeta.new(@id, @first.not_nil!, @last.not_nil!, @count)
    end

    private def flush_block : Nil
      data = @pending.to_slice
      offset = @io.pos
      Util.write_varint(@io, data.size.to_u64)
      @io.write(data)
      total = Util.varint_len(data.size.to_u64) + data.size
      if @checksums
        @io.write_bytes(Util.crc32(data), IO::ByteFormat::LittleEndian)
        total += 4
      end
      @index << BlockIndexEntry.new(@pending_keys.first, offset.to_u64, total.to_u64)
      @pending = IO::Memory.new
      @pending_keys = [] of String
    end
  end

  # Reads a sorted table that `SstableWriter` produced.
  class SstableReader
    @path : String
    @file_id : Int64
    @cache : BlockCache?
    @file : File
    @size : Int64
    @index : Array(BlockIndexEntry)
    @bloom : BloomFilter?
    @closed : Bool
    @index_offset : UInt64
    @index_length : UInt64
    @bloom_offset : UInt64
    @bloom_length : UInt64
    @version : UInt32

    def initialize(@path : String, @file_id : Int64, @cache : BlockCache? = nil)
      @file = File.open(@path, "r")
      @size = @file.size
      @index = [] of BlockIndexEntry
      @bloom = nil
      @closed = false
      @index_offset = 0_u64
      @index_length = 0_u64
      @bloom_offset = 0_u64
      @bloom_length = 0_u64
      @version = 0_u32
      read_footer
      read_index
      read_bloom
    end

    def path : String
      @path
    end

    def file_id : Int64
      @file_id
    end

    def block_count : Int32
      @index.size
    end

    def first_key : String
      @index.empty? ? "" : @index.first.first_key
    end

    def close : Nil
      return if @closed
      @closed = true
      @file.close
    end

    # Decodes all entries in block `idx`.
    def load_block_entries(idx : Int32) : Array(Entry)
      Cinderstore.decode_entries(read_block(idx))
    end

    # Returns the index of the block that may contain `key`.
    #
    # Returns the last block whose first key is <= `key`, or block zero.
    def find_block_for(key : String) : Int32
      lo = 0
      hi = @index.size - 1
      ans = -1
      while lo <= hi
        mid = (lo + hi) // 2
        if @index[mid].first_key <= key
          ans = mid
          lo = mid + 1
        else
          hi = mid - 1
        end
      end
      ans == -1 ? 0 : ans
    end

    # Returns false only when the bloom filter proves `key` is absent.
    def bloom_may_contain?(key : String) : Bool
      bloom = @bloom
      bloom ? bloom.includes?(key) : true
    end

    private def read_block(idx : Int32) : Bytes
      entry = @index[idx]
      if cache = @cache
        return cache.fetch("#{@file_id}:#{idx}") { read_block_raw(entry) }
      end
      read_block_raw(entry)
    end

    private def read_block_raw(entry : BlockIndexEntry) : Bytes
      @file.pos = entry.offset
      data_len = Util.read_varint(@file).to_i
      expected = data_len.to_u64 + Util.varint_len(data_len.to_u64).to_u64
      expected += 4_u64 if @version == SstableWriter::VERSION_CHECKSUMMED
      if expected != entry.length
        raise CorruptDataError.new("block length mismatch in #{@path}")
      end
      data = Bytes.new(data_len)
      @file.read_fully(data)
      if @version == SstableWriter::VERSION_CHECKSUMMED
        stored_crc = @file.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        actual_crc = Util.crc32(data)
        raise CorruptDataError.new("block checksum mismatch in #{@path}") unless stored_crc == actual_crc
      end
      data
    end

    private def read_footer : Nil
      raise CorruptDataError.new("file too small: #{@path}") if @size < SstableWriter::FOOTER_SIZE
      @file.pos = @size - SstableWriter::FOOTER_SIZE
      footer = Bytes.new(SstableWriter::FOOTER_SIZE)
      @file.read_fully(footer)

      io = IO::Memory.new(footer)
      magic = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      raise CorruptDataError.new("bad magic in #{@path}") unless magic == SstableWriter::MAGIC
      @index_offset = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      @index_length = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      @bloom_offset = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      @bloom_length = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      @version = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      case @version
      when SstableWriter::VERSION_CHECKSUMMED
        crc_bytes = footer[SstableWriter::FOOTER_SIZE - 4, 4]
        stored_crc = IO::Memory.new(crc_bytes).read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        actual_crc = Util.crc32(footer[0, SstableWriter::FOOTER_SIZE - 4])
        raise CorruptDataError.new("footer checksum mismatch in #{@path}") unless stored_crc == actual_crc
      when SstableWriter::VERSION_FAST
        # No checksum to verify in the fast format.
      else
        raise CorruptDataError.new("unsupported version #{@version} in #{@path}")
      end
    end

    private def read_index : Nil
      @file.pos = @index_offset
      count = Util.read_varint(@file).to_i
      count.times do
        key_len = Util.read_varint(@file).to_i
        key = @file.read_string(key_len)
        offset = Util.read_varint(@file)
        length = Util.read_varint(@file)
        @index << BlockIndexEntry.new(key, offset, length)
      end
    end

    private def read_bloom : Nil
      @file.pos = @bloom_offset
      @bloom = BloomFilter.deserialize(@file)
    end
  end
end
