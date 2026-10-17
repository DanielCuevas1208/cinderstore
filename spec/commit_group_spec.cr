require "./spec_helper"

# A helper that runs `writers` concurrent fibers, each calling `work`, and
# waits for every fiber to finish.
private def run_concurrently(count : Int32, &work : Int32 ->) : Nil
  done = Channel(Nil).new
  count.times do |i|
    spawn do
      work.call(i)
      done.send(nil)
    end
  end
  count.times { done.receive }
end

describe Cinderstore::CommitGroup do
  it "syncs once for a burst of concurrent writers" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("group")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000001.wal")
    writer = Cinderstore::Wal::Writer.new(path, true)
    group = Cinderstore::CommitGroup.new
    begin
      run_concurrently(8) do |i|
        writer.append(Cinderstore::Entry.new("k#{i}", i.to_i64, true, "v"))
        group.commit(writer)
      end
      group.commits.should eq(1_i64)
    ensure
      group.shutdown
      writer.close
    end
  end

  it "syncs each sequential write" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("group")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000001.wal")
    writer = Cinderstore::Wal::Writer.new(path, true)
    group = Cinderstore::CommitGroup.new
    begin
      5.times do |i|
        writer.append(Cinderstore::Entry.new("k#{i}", i.to_i64, true, "v"))
        group.commit(writer)
      end
      group.commits.should eq(5_i64)
    ensure
      group.shutdown
      writer.close
    end
  end
end

describe Cinderstore::DB do
  it "coalesces durability syncs for concurrent writers" do
    config = Cinderstore::SpecHelpers.fast_config
    config.sync_writes = true
    Cinderstore::SpecHelpers.with_db("db-group", config) do |db, _path|
      run_concurrently(8) do |i|
        25.times do |j|
          db.put("k%d-%02d" % {i, j}, "v")
        end
      end
      db.stats.writes.should eq(200)
      db.stats.commits.should be >= 1
      db.stats.commits.should be <= 25
      db.scan.size.should eq(200)
    end
  end

  it "recovers group-committed writes after a restart" do
    config = Cinderstore::SpecHelpers.fast_config
    config.sync_writes = true
    Cinderstore::SpecHelpers.with_db_path("db-group-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      run_concurrently(4) do |i|
        10.times do |j|
          db.put("k%d-%02d" % {i, j}, "value-#{j}")
        end
      end
      db.close

      reopened = Cinderstore::DB.new(path, config)
      reopened.scan.size.should eq(40)
      reopened.get("k2-07").should eq("value-7")
      reopened.close
    end
  end
end
