require "./spec_helper"
require "socket"

private def wait_until_ready(server : Cinderstore::Server, timeout : Time::Span = 5.seconds) : Nil
  deadline = Time.instant + timeout
  until server.ready?
    raise "server did not start in time" if Time.instant >= deadline
    sleep 10.milliseconds
  end
end

private def with_server(db : Cinderstore::DB, &)
  server = Cinderstore::Server.new(db, "127.0.0.1", 0)
  spawn { server.run }
  wait_until_ready(server)
  begin
    yield server
  ensure
    server.stop
    sleep 10.milliseconds
  end
end

private def send_command(sock : TCPSocket, command : String) : String?
  sock << command << "\n"
  sock.flush
  sock.gets
end

describe Cinderstore::DB do
  it "streams the primary keys behind one index key in order" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-exact", config) do |db, _path|
      db.create_index("by-group") { |key, _value| [key[0..0]] }
      db.put("apple", "1")
      db.put("apricot", "2")
      db.put("avocado", "3")
      db.put("plum", "4")
      iter = db.query_iter("by-group", "a")
      keys = [] of String
      while key = iter.next?
        keys << key
      end
      iter.close
      keys.should eq(%w[apple apricot avocado])
    end
  end

  it "matches the materialized query result" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-parity", config) do |db, _path|
      db.create_json_index("by-price", "price")
      db.put("a", %({"price":10}))
      db.put("b", %({"price":20}))
      db.put("c", %({"price":20}))
      db.put("d", %({"price":30}))
      iter = db.query_iter("by-price", "20")
      iter.to_a.should eq(db.query("by-price", "20"))
      iter.close
    end
  end

  it "stops early and still releases the snapshot on close" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-early", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      5.times { |i| db.put("k#{i}", "v") }
      iter = db.query_iter("by-value", "v")
      iter.next?.should eq("k0")
      iter.next?.should eq("k1")
      iter.close
      expect_raises(Cinderstore::SnapshotReleasedError) { iter.next? }
    end
  end

  it "streams a range in index key order with an upper bound" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-range", config) do |db, _path|
      db.create_json_index("by-price", "price")
      db.put("a", %({"price":10}))
      db.put("b", %({"price":20}))
      db.put("c", %({"price":30}))
      db.put("d", %({"price":40}))
      iter = db.query_range_iter("by-price", "10", "30")
      iter.to_a.should eq(%w[a b])
      iter.close
      iter = db.query_range_iter("by-price")
      iter.to_a.should eq(%w[a b c d])
      iter.close
    end
  end

  it "streams empty results without error" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-empty", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "x")
      iter = db.query_iter("by-value", "missing")
      iter.next?.should be_nil
      iter.close
      iter = db.query_range_iter("by-value", "y", "z")
      iter.to_a.should be_empty
      iter.close
    end
  end

  it "skips deleted keys and moved values" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-live", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "x")
      db.put("b", "x")
      db.delete("a")
      db.put("c", "y")
      iter = db.query_iter("by-value", "x")
      iter.to_a.should eq(%w[b])
      iter.close
      iter = db.query_iter("by-value", "y")
      iter.to_a.should eq(%w[c])
      iter.close
    end
  end

  it "streams across flush and compaction boundaries" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-tables", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "x")
      db.flush
      db.put("b", "x")
      db.flush
      db.put("c", "x")
      db.flush
      db.compact
      iter = db.query_iter("by-value", "x")
      iter.to_a.should eq(%w[a b c])
      iter.close
    end
  end

  it "reads from tables even without a registered index" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("iter-materialized") do |path|
      db = Cinderstore::DB.new(path, config)
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "x")
      db.put("b", "x")
      db.close

      reopened = Cinderstore::DB.new(path, config)
      iter = reopened.query_iter("by-value", "x")
      iter.to_a.should eq(%w[a b])
      iter.close
      reopened.close
    end
  end

  it "yields keys through the block form" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-block", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "x")
      db.put("b", "x")
      iter = db.query_iter("by-value", "x")
      keys = [] of String
      iter.each { |key| keys << key }
      iter.close
      keys.should eq(%w[a b])
    end
  end

  it "rejects invalid index names" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-invalid", config) do |db, _path|
      expect_raises(Cinderstore::InvalidIndexError) do
        db.query_iter("", "v")
      end
      expect_raises(Cinderstore::InvalidIndexError) do
        db.query_range_iter("a\u{0000}b")
      end
    end
  end

  it "keeps a snapshot iterator stable across later writes" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-snapshot", config) do |db, _path|
      db.create_json_index("by-x", "x")
      db.put("a", %({"x":1}))
      snap = db.snapshot
      db.put("b", %({"x":1}))
      db.delete("a")
      iter = snap.query_iter("by-x", "1")
      iter.to_a.should eq(%w[a])
      iter.close
      db.query_iter("by-x", "1").to_a.should eq(%w[b])
      snap.release
    end
  end

  it "does not release the caller snapshot on close" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-norelease", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      db.put("a", "x")
      snap = db.snapshot
      iter = snap.query_iter("by-value", "x")
      iter.to_a.should eq(%w[a])
      iter.close
      snap.count.should eq(1)
      snap.get("a").should eq("x")
      snap.release
    end
  end

  it "keeps a snapshot range stream stable across a delete" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-snapshot-range", config) do |db, _path|
      db.create_json_index("by-x", "x")
      db.put("a", %({"x":1}))
      db.put("b", %({"x":2}))
      snap = db.snapshot
      db.delete("a")
      iter = snap.query_range_iter("by-x")
      iter.to_a.should eq(%w[a b])
      iter.close
      snap.release
    end
  end
end

describe Cinderstore::Server do
  it "streams query results over the socket" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-server", config) do |db, _path|
      db.create_json_index("by-price", "price")
      with_server(db) do |server|
        sock = TCPSocket.new("127.0.0.1", server.port)
        send_command(sock, "PUT a {\"price\":10}").should eq("OK")
        send_command(sock, "PUT b {\"price\":20}").should eq("OK")
        send_command(sock, "PUT c {\"price\":20}").should eq("OK")

        sock << "QUERY by-price 20\n"
        sock.flush
        rows = [] of String
        while (line = sock.gets) && line != "END"
          rows << line
        end
        rows.should eq(["ROW b", "ROW c"])

        sock << "QUERYRANGE by-price 10 20\n"
        sock.flush
        rows = [] of String
        while (line = sock.gets) && line != "END"
          rows << line
        end
        rows.should eq(["ROW a"])
        sock.close
      end
    end
  end

  it "streams an empty query as a single END line" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("iter-server-empty", config) do |db, _path|
      db.create_index("by-value") { |_key, value| [value] }
      with_server(db) do |server|
        sock = TCPSocket.new("127.0.0.1", server.port)
        send_command(sock, "PUT a x").should eq("OK")
        sock << "QUERY by-value missing\n"
        sock.flush
        sock.gets.should eq("END")
        sock.close
      end
    end
  end
end
