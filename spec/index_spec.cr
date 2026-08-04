require "./spec_helper"

describe Cinderstore::DB do
  it "indexes new values and returns the matching primary keys" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-basic", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "one")
      db.put("b", "two")
      db.query("by-value", "one").should eq(%w[a])
      db.query("by-value", "two").should eq(%w[b])
      db.query("by-value", "three").should eq([] of String)
    end
  end

  it "returns primary keys in primary key order for one index key" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-order", config) do |db, _path|
      db.create_index("by-group") { |key, _value| [key[0..0]] }
      db.put("apple", "1")
      db.put("apricot", "2")
      db.put("avocado", "3")
      db.query("by-group", "a").should eq(%w[apple apricot avocado])
    end
  end

  it "supports a limit on exact queries" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-limit", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      3.times { |i| db.put("k#{i}", "v") }
      db.query("by-value", "v", 2).should eq(%w[k0 k1])
    end
  end

  it "moves a key between index values when its value changes" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-update", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "x")
      db.put("a", "y")
      db.query("by-value", "x").should eq([] of String)
      db.query("by-value", "y").should eq(%w[a])
    end
  end

  it "removes a key from every index on delete" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-delete", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "x")
      db.put("b", "x")
      db.delete("a")
      db.query("by-value", "x").should eq(%w[b])
    end
  end

  it "re-indexes a key after a delete" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-resurrect", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "x")
      db.delete("a")
      db.put("a", "y")
      db.query("by-value", "x").should eq([] of String)
      db.query("by-value", "y").should eq(%w[a])
    end
  end

  it "keeps the index correct across flush boundaries" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-flush", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "x")
      db.flush
      db.put("a", "y")
      db.flush
      db.query("by-value", "x").should eq([] of String)
      db.query("by-value", "y").should eq(%w[a])
    end
  end

  it "drops stale index entries during compaction" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-compact", config) do |db, path|
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "x")
      db.flush
      db.put("a", "y")
      db.flush
      db.put("b", "x")
      db.flush
      db.compact
      db.query("by-value", "x").should eq(%w[b])
      db.query("by-value", "y").should eq(%w[a])
      db.scan.map(&.[0]).should eq(%w[a b])
    end
  end

  it "recovers the index after a restart" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("idx-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "x")
      db.put("b", "x")
      db.flush
      db.put("c", "y")
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.query("by-value", "x").should eq(%w[a b])
      reopened.query("by-value", "y").should eq(%w[c])
      reopened.close
    end
  end

  it "answers queries without a registered index" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("idx-materialized") do |path|
      db = Cinderstore::DB.new(path, config)
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "x")
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.query("by-value", "x").should eq(%w[a])
      reopened.query("by-value", "x").should eq(%w[a])
      reopened.close
    end
  end

  it "maintains the index through batch writes" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-batch", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      db.write do |b|
        b.put("a", "x")
        b.put("a", "y")
      end
      db.query("by-value", "x").should eq([] of String)
      db.query("by-value", "y").should eq(%w[a])
    end
  end

  it "recovers the index after a batch restart" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("idx-batchrestart") do |path|
      db = Cinderstore::DB.new(path, config)
      db.create_index("by-value") { |_key, value| [value] }
      db.write do |b|
        b.put("a", "x")
        b.put("b", "y")
      end
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.query("by-value", "x").should eq(%w[a])
      reopened.query("by-value", "y").should eq(%w[b])
      reopened.close
    end
  end

  it "hides index entries from scans, gets, and stats" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-hidden", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "1")
      db.put("b", "2")
      db.flush
      db.scan.map(&.[0]).should eq(%w[a b])
      db.get("a").should eq("1")
      db.stats.entries.should eq(2_i64)
      db.stats.entries.should eq(db.scan.size.to_i64)
    end
  end

  it "extracts scalar and array JSON fields" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-json", config) do |db, _path|
      db.create_json_index("by-tag", "tags")
      db.create_json_index("by-price", "price")
      db.put("k1", %({"tags":["red","blue"],"price":14.00}))
      db.put("k2", %({"tags":["green"],"price":20.50}))
      db.query("by-tag", "red").should eq(%w[k1])
      db.query("by-tag", "blue").should eq(%w[k1])
      db.query("by-tag", "green").should eq(%w[k2])
      db.query("by-price", "14.0").should eq(%w[k1])
      db.query("by-price", "20.5").should eq(%w[k2])
    end
  end

  it "skips values that are not JSON or lack the field" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-jsonmiss", config) do |db, _path|
      db.create_json_index("by-x", "x")
      db.put("k1", %({"y":1}))
      db.put("k2", "not json")
      db.put("k3", %({"x":"found"}))
      db.query("by-x", "found").should eq(%w[k3])
      db.scan.map(&.[0]).should eq(%w[k1 k2 k3])
    end
  end

  it "returns range results in index key order" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-range", config) do |db, _path|
      db.create_json_index("by-price", "price")
      db.put("a", %({"price":10}))
      db.put("b", %({"price":20}))
      db.put("c", %({"price":30}))
      db.query_range("by-price", "10", "30").should eq(%w[a b])
      db.query_range("by-price", "", "40").should eq(%w[a b c])
      db.query_range("by-price", "", nil, 2).should eq(%w[a b])
      db.query_range("by-price").should eq(%w[a b c])
    end
  end

  it "keeps a snapshot query stable across later writes" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-snapshot", config) do |db, _path|
      db.create_json_index("by-x", "x")
      db.put("a", %({"x":1}))
      snap = db.snapshot
      db.put("b", %({"x":1}))
      db.delete("a")
      snap.query("by-x", "1").should eq(%w[a])
      db.query("by-x", "1").should eq(%w[b])
      snap.release
    end
  end

  it "supports querying a snapshot that spans tables" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-snaptables", config) do |db, _path|
      db.create_json_index("by-x", "x")
      db.put("a", %({"x":1}))
      db.flush
      db.put("b", %({"x":1}))
      db.flush
      snap = db.snapshot
      db.put("c", %({"x":1}))
      snap.query("by-x", "1").should eq(%w[a b])
      db.query("by-x", "1").should eq(%w[a b c])
      snap.release
    end
  end

  it "lists registered indexes" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-list", config) do |db, _path|
      db.create_index("one") { |_key, _value| [] of String }
      db.create_json_index("two", "price")
      db.indexes.should eq(%w[one two])
      db.index?("one").should be_true
      db.index?("nope").should be_false
    end
  end

  it "rejects invalid index names" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-invalid", config) do |db, _path|
      expect_raises(Cinderstore::InvalidIndexError) do
        db.create_index("") { |_key, _value| [] of String }
      end
      expect_raises(Cinderstore::InvalidIndexError) do
        db.create_index("a\u{0000}b") { |_key, _value| [] of String }
      end
      db.create_index("dup") { |_key, _value| [] of String }
      expect_raises(Cinderstore::InvalidIndexError) do
        db.create_index("dup") { |_key, _value| [] of String }
      end
    end
  end

  it "rejects index keys that contain a NUL byte" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-nulkey", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      expect_raises(Cinderstore::InvalidIndexError) { db.put("a", "bad\u{0000}key") }
    end
  end

  it "rejects primary keys in the reserved namespace" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("idx-reserved", config) do |db, _path|
      reserved = Cinderstore::Index::NAMESPACE + "x"
      expect_raises(Cinderstore::InvalidKeyError) { db.put(reserved, "v") }
      expect_raises(Cinderstore::InvalidKeyError) { db.get(reserved) }
    end
  end

  it "rejects NUL-containing keys only while an index exists" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("idx-nulprimary") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("a\u{0000}b", "v")
      db.get("a\u{0000}b").should eq("v")
      db.close

      indexed = Cinderstore::DB.new(path, config)
      indexed.create_index("by-value") { |_key, value| [value] }
      expect_raises(Cinderstore::InvalidKeyError) { indexed.put("a\u{0000}b", "w") }
      indexed.close
    end
  end

  it "stays consistent under concurrent writes" do
    config = Cinderstore::SpecHelpers.fast_config
    config.memtable_limit = 1_i64 << 30
    Cinderstore::SpecHelpers.with_db("idx-concurrent", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      done = Channel(Nil).new
      8.times do |i|
        spawn do
          20.times do |j|
            db.put("k-%d-%02d" % {i, j}, "v-#{i}")
          end
          done.send(nil)
        end
      end
      8.times { done.receive }
      8.times do |i|
        keys = db.query("by-value", "v-#{i}")
        keys.size.should eq(20)
        keys.each { |key| key.should start_with("k-#{i}-") }
      end
    end
  end

  it "keeps existing data readable when an index is added later" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("idx-parity") do |path|
      plain = Cinderstore::DB.new(path, config)
      5.times { |i| plain.put("k#{i}", "v#{i}") }
      plain.close

      indexed = Cinderstore::DB.new(path, config)
      indexed.create_index("by-value") { |_key, value| [value] }
      indexed.put("extra", "v9")
      indexed.scan.map(&.[0]).should eq(%w[extra k0 k1 k2 k3 k4])
      indexed.stats.entries.should eq(6_i64)
      indexed.close
    end
  end
end
