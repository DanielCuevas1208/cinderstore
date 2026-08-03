require "json"

module Cinderstore
  # The durable catalog of table files.
  #
  # The manifest stores the sequence counter, the next file id, and the
  # tables grouped by level. It is rewritten atomically through a temp file
  # and a rename.
  class Manifest
    # A table reference as recorded in the manifest.
    class TableInfo
      include JSON::Serializable
      property id : Int64 = 0_i64
      property first : String = ""
      property last : String = ""
      property count : Int64 = 0_i64

      def initialize
      end

      def initialize(@id : Int64, @first : String, @last : String, @count : Int64)
      end
    end

    include JSON::Serializable

    property seq : Int64 = 0_i64
    property next_id : Int64 = 1_i64
    property levels : Array(Array(TableInfo)) = [[] of TableInfo]

    def initialize
    end

    # Loads the manifest, or returns a fresh one when absent.
    def self.load(path : String) : Manifest
      File.exists?(path) ? Manifest.from_json(File.read(path)) : Manifest.new
    end

    # Writes the manifest atomically.
    def save(path : String) : Nil
      tmp = "#{path}.tmp"
      File.write(tmp, to_json)
      File.rename(tmp, path)
    end
  end
end
