require "spec"
require "file_utils"
require "../src/cinderstore"

module Cinderstore
  module SpecHelpers
    # Returns a fresh, unused database directory.
    def self.tmp_db_path(prefix : String = "spec") : String
      File.join(Dir.tempdir, "cinderstore-spec-#{prefix}-#{Random::Secure.hex(6)}")
    end

    # Runs a block with a database that lives in a throwaway directory.
    def self.with_db(prefix : String = "spec", config = DB::Config.new, &)
      path = tmp_db_path(prefix)
      db = DB.new(path, config)
      begin
        yield db, path
      ensure
        db.close rescue nil
        FileUtils.rm_rf(path)
      end
    end

    # Runs a block with a database that lives in a throwaway directory.
    # The block may close and reopen the database itself.
    def self.with_db_path(prefix : String = "spec", &)
      path = tmp_db_path(prefix)
      begin
        yield path
      ensure
        FileUtils.rm_rf(path)
      end
    end

    # Truncates a file to `size` bytes. Simulates a torn write.
    def self.truncate(path : String, size : Int64) : Nil
      File.open(path, "r+") { |f| f.truncate(size) }
    end

    # Returns a config that writes quickly for most tests.
    def self.fast_config : DB::Config
      config = DB::Config.new
      config.sync_writes = false
      config.compact_on_flush = false
      config
    end

    # Returns a config tuned for small flushes and tiny tables.
    def self.small_config(block_size : Int32 = 256, memtable_limit : Int64 = 4096) : DB::Config
      config = fast_config
      config.block_size = block_size
      config.memtable_limit = memtable_limit
      config
    end
  end
end
