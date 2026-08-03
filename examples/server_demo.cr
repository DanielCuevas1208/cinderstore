# Starts a local server and talks to it over the wire protocol.
#
# Usage: crystal run examples/server_demo.cr
require "socket"
require "file_utils"
require "../src/cinderstore"

path = File.join(Dir.tempdir, "cinderstore-server-demo")
FileUtils.rm_rf(path) if File.exists?(path)
config = Cinderstore::DB::Config.new
config.sync_writes = true
db = Cinderstore::DB.new(path, config)
server = Cinderstore::Server.new(db, "127.0.0.1", 0)

spawn { server.run }
while !server.ready?
  Fiber.yield
end

def send(socket, command)
  socket << command << "\n"
  socket.flush
  socket.gets
end

sock = TCPSocket.new("127.0.0.1", server.port)
puts "PUT forge-hammer => #{send(sock, "PUT forge-hammer steel 1.5kg")}"
puts "PUT forge-tongs  => #{send(sock, "PUT forge-tongs long reach")}"
puts "GET forge-hammer => #{send(sock, "GET forge-hammer")}"
puts "GET missing      => #{send(sock, "GET nope")}"
puts "DEL forge-tongs  => #{send(sock, "DEL forge-tongs")}"
puts "STATS            => #{send(sock, "STATS")}"
puts "SHUTDOWN         => #{send(sock, "SHUTDOWN")}"
sock.close

attempts = 100
attempts.times do
  break unless server.ready?
  sleep 20.milliseconds
end

db.close
puts "server demo complete"
