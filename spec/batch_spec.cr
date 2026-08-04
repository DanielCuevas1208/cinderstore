require "./spec_helper"

describe Cinderstore::Batch do
  it "counts queued operations" do
    batch = Cinderstore::Batch.new
    batch.empty?.should be_true
    batch.put("a", "1")
    batch.delete("b")
    batch.empty?.should be_false
    batch.size.should eq(2)
  end

  it "yields operations in queue order" do
    batch = Cinderstore::Batch.new
    batch.put("a", "1")
    batch.delete("b")
    batch.put("c", "3")
    ops = [] of Tuple(String, String, Bool)
    batch.each do |key, value, alive|
      ops << {key, value, alive}
    end
    ops.should eq([{"a", "1", true}, {"b", "", false}, {"c", "3", true}])
  end
end

describe Cinderstore::DB do
  it "writes a batch and reads it back" do
    Cinderstore::SpecHelpers.with_db("batch-basic") do |db, _path|
      batch = Cinderstore::Batch.new
      batch.put("alpha", "one")
      batch.put("beta", "two")
      db.write(batch)
      db.get("alpha").should eq("one")
      db.get("beta").should eq("two")
      db.scan.size.should eq(2)
    end
  end

  it "writes a batch built in a block" do
    Cinderstore::SpecHelpers.with_db("batch-block") do |db, _path|
      db.write do |b|
        b.put("a", "1")
        b.put("b", "2")
      end
      db.scan.map(&.[0]).should eq(%w[a b])
    end
  end

  it "applies puts and deletes in one batch" do
    Cinderstore::SpecHelpers.with_db("batch-mixed") do |db, _path|
      db.put("keep", "v")
      db.put("drop", "v")
      db.write do |b|
        b.put("add", "v")
        b.delete("drop")
      end
      db.scan.map(&.[0]).should eq(%w[add keep])
      db.get("drop").should be_nil
    end
  end

  it "lets a later batch operation win for the same key" do
    Cinderstore::SpecHelpers.with_db("batch-overwrite") do |db, _path|
      db.write do |b|
        b.put("k", "first")
        b.put("k", "second")
      end
      db.get("k").should eq("second")
      db.scan.size.should eq(1)
    end
  end

  it "lets a delete in a batch hide an earlier put" do
    Cinderstore::SpecHelpers.with_db("batch-hide") do |db, _path|
      db.write do |b|
        b.put("k", "v")
        b.delete("k")
      end
      db.get("k").should be_nil
      db.scan.size.should eq(0)
    end
  end

  it "lets a put in a batch override an earlier delete" do
    Cinderstore::SpecHelpers.with_db("batch-resurrect") do |db, _path|
      db.write do |b|
        b.delete("k")
        b.put("k", "v")
      end
      db.get("k").should eq("v")
      db.scan.size.should eq(1)
    end
  end

  it "treats an empty batch as a no-op" do
    Cinderstore::SpecHelpers.with_db("batch-empty") do |db, _path|
      batch = Cinderstore::Batch.new
      db.write(batch)
      db.stats.seq.should eq(0)
      db.stats.writes.should eq(0)
      db.scan.size.should eq(0)
    end
  end

  it "assigns consecutive sequence numbers within a batch" do
    Cinderstore::SpecHelpers.with_db("batch-seq") do |db, _path|
      db.write do |b|
        3.times { |i| b.put("k#{i}", "v") }
      end
      db.stats.seq.should eq(3)
    end
  end

  it "counts one batch as one write operation" do
    Cinderstore::SpecHelpers.with_db("batch-stats") do |db, _path|
      db.write do |b|
        10.times { |i| b.put("k%02d" % i, "v") }
      end
      db.stats.writes.should eq(1)
      db.stats.entries.should eq(10)
    end
  end

  it "rejects an oversized value and leaves the store unchanged" do
    Cinderstore::SpecHelpers.with_db("batch-invalid") do |db, _path|
      db.put("before", "v")
      batch = Cinderstore::Batch.new
      batch.put("good", "v")
      batch.put("bad", "x" * (Cinderstore::DB::MAX_VALUE_BYTES + 1))
      expect_raises(Cinderstore::InvalidValueError) { db.write(batch) }
      db.get("before").should eq("v")
      db.get("good").should be_nil
      db.stats.writes.should eq(1)
    end
  end

  it "rejects an invalid key inside a batch" do
    Cinderstore::SpecHelpers.with_db("batch-key") do |db, _path|
      batch = Cinderstore::Batch.new
      batch.put("", "v")
      expect_raises(Cinderstore::InvalidKeyError) { db.write(batch) }
    end
  end

  it "recovers a batch across a restart" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("batch-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      db.write do |b|
        20.times { |i| b.put("row-%02d" % i, "value-#{i}") }
      end
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.scan.size.should eq(20)
      reopened.get("row-07").should eq("value-7")
      reopened.close
    end
  end

  it "recovers a batch written in fast mode" do
    config = Cinderstore::SpecHelpers.fast_config
    config.checksums = false
    Cinderstore::SpecHelpers.with_db_path("batch-fast") do |path|
      db = Cinderstore::DB.new(path, config)
      db.write do |b|
        10.times { |i| b.put("k%02d" % i, "v-#{i}") }
      end
      db.close

      reopened = Cinderstore::DB.new(path)
      reopened.scan.size.should eq(10)
      reopened.get("k03").should eq("v-3")
      reopened.close
    end
  end

  it "flushes and compacts batch-written data" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("batch-compact", config) do |db, _path|
      db.write do |b|
        40.times { |i| b.put("k%02d" % i, "v-#{i}") }
      end
      db.flush
      db.put("k00", "updated")
      db.flush
      db.compact
      db.stats.tables.should eq(1)
      db.get("k00").should eq("updated")
      db.scan.size.should eq(40)
    end
  end

  it "keeps a batch-created snapshot view stable" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("batch-snapshot", config) do |db, _path|
      db.write do |b|
        b.put("a", "1")
        b.put("b", "2")
      end
      snap = db.snapshot
      db.write do |b|
        b.put("c", "3")
        b.delete("a")
      end
      snap.get("a").should eq("1")
      snap.get("c").should be_nil
      snap.release
      db.get("a").should be_nil
      db.get("c").should eq("3")
    end
  end
end
