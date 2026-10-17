require "json"

module Cinderstore
  # Reserved namespace and key layout for secondary indexes.
  #
  # An index entry is an ordinary entry whose key starts with NAMESPACE.
  # The key has this layout:
  #
  #   NAMESPACE + name + SEP + index_key + SEP + primary_key
  #
  # The entries share the main log structured merge tree with the primary
  # data. They ride the same write ahead log, sorted tables, compaction,
  # and recovery. A newer tombstone supersedes a stale entry, exactly as
  # it does for primary keys.
  module Index
    # Reserved prefix for every internal index entry.
    NAMESPACE = "\u{0000}idx\u{0000}"
    # Byte that separates the parts of an index entry key.
    SEP = '\u{0000}'

    # Returns the stored key for one index association.
    def self.entry_key(name : String, index_key : String, primary_key : String) : String
      "#{NAMESPACE}#{name}#{SEP}#{index_key}#{SEP}#{primary_key}"
    end

    # Returns the key prefix that covers every entry of one index.
    def self.name_prefix(name : String) : String
      "#{NAMESPACE}#{name}#{SEP}"
    end

    # Returns the key prefix that covers every entry of one index key.
    def self.exact_prefix(name : String, index_key : String) : String
      "#{name_prefix(name)}#{index_key}#{SEP}"
    end

    # Returns true when `key` belongs to the internal index namespace.
    def self.internal_key?(key : String) : Bool
      key.starts_with?(NAMESPACE)
    end

    # Splits an index entry key into its name, index key, and primary key.
    def self.split_entry(key : String) : Tuple(String, String, String)
      raise CorruptDataError.new("not an index entry key") unless key.starts_with?(NAMESPACE)
      rest = key[NAMESPACE.size..]
      first = rest.index(SEP)
      raise CorruptDataError.new("malformed index entry key") unless first
      name = rest[0, first]
      rest = rest[first + 1..]
      second = rest.index(SEP)
      raise CorruptDataError.new("malformed index entry key") unless second
      index_key = rest[0, second]
      primary_key = rest[second + 1..]
      {name, index_key, primary_key}
    end

    # Returns the index key part of an index entry key.
    def self.index_key_of(key : String) : String
      split_entry(key)[1]
    end

    # Returns the primary key part of an index entry key.
    def self.primary_key_of(key : String) : String
      split_entry(key)[2]
    end

    # Extracts the string keys for a JSON value field.
    #
    # A scalar field yields one key. An array field yields one key per
    # element. A missing field or a non-scalar value yields no keys. A
    # value that is not JSON yields no keys, so it never breaks a write.
    def self.json_field_keys(doc : JSON::Any, field : String) : Array(String)
      return [] of String if field.empty?
      value = doc[field]?
      return [] of String unless value
      keys = [] of String
      case raw = value.raw
      when String, Int64, Float64, Bool
        keys << raw.to_s
      when Array
        raw.each do |item|
          case item.raw
          when String, Int64, Float64, Bool
            keys << item.raw.to_s
          end
        end
      end
      keys
    end
  end
end
