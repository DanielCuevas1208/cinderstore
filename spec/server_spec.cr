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

describe Cinderstore::Server do
  it "serves put, get, and delete over a socket" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("server-basic", config) do |db, _path|
      with_server(db) do |server|
        sock = TCPSocket.new("127.0.0.1", server.port)
        send_command(sock, "PUT forge-hammer steel").should eq("OK")
        send_command(sock, "PUT forge-tongs  long reach").should eq("OK")
        send_command(sock, "GET forge-hammer").should eq("VALUE steel")
        send_command(sock, "GET nope").should eq("NOT_FOUND")
        send_command(sock, "DEL forge-tongs").should eq("OK")
        send_command(sock, "GET forge-tongs").should eq("NOT_FOUND")
        sock.close
      end
    end
  end

  it "scans a range" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("server-scan", config) do |db, _path|
      with_server(db) do |server|
        sock = TCPSocket.new("127.0.0.1", server.port)
        send_command(sock, "PUT a one").should eq("OK")
        send_command(sock, "PUT b two").should eq("OK")
        send_command(sock, "PUT c three").should eq("OK")

        sock << "SCAN a c\n"
        sock.flush
        rows = [] of String
        while (line = sock.gets) && line != "END"
          rows << line
        end
        rows.should eq(["ROW a one", "ROW b two"])
        sock.close
      end
    end
  end

  it "reports protocol errors" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("server-errors", config) do |db, _path|
      with_server(db) do |server|
        sock = TCPSocket.new("127.0.0.1", server.port)
        send_command(sock, "BOGUS").not_nil!.should start_with("ERR")
        send_command(sock, "GET").not_nil!.should start_with("ERR")
        send_command(sock, "PUT onlykey").not_nil!.should start_with("ERR")
        sock.close
      end
    end
  end

  it "replies to ping and reports stats" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("server-ping", config) do |db, _path|
      with_server(db) do |server|
        sock = TCPSocket.new("127.0.0.1", server.port)
        send_command(sock, "PING").should eq("PONG")
        send_command(sock, "PUT a 1").should eq("OK")
        send_command(sock, "STATS").not_nil!.should start_with("STATS {")
        sock.close
      end
    end
  end

  it "shuts down on command" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("server-shutdown", config) do |db, _path|
      server = Cinderstore::Server.new(db, "127.0.0.1", 0)
      spawn { server.run }
      wait_until_ready(server)
      sock = TCPSocket.new("127.0.0.1", server.port)
      send_command(sock, "SHUTDOWN").should eq("BYE")
      sock.close
      sleep 10.milliseconds
      server.ready?.should be_false
    end
  end
end
