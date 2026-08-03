# Shows how a snapshot keeps a consistent view across writes.
#
# Usage: crystal run examples/snapshot_demo.cr
require "file_utils"
require "../src/cinderstore"

path = File.join(Dir.tempdir, "cinderstore-snapshot-demo")
FileUtils.rm_rf(path) if File.exists?(path)
config = Cinderstore::DB::Config.new
config.sync_writes = false
config.compact_on_flush = false
db = Cinderstore::DB.new(path, config)

db.put("forge-hammer", "steel")
db.put("forge-tongs", "iron")
db.flush

view = db.snapshot
puts "snapshot sequence: #{view.seq}"
puts "snapshot rows: #{view.scan.size}"

db.delete("forge-tongs")
db.put("anvil", "45kg")
db.flush
db.compact

puts "live rows after writes: #{db.scan.size}"
puts "snapshot rows after writes: #{view.scan.size}"
puts "snapshot get forge-tongs: #{view.get("forge-tongs").inspect}"
puts "live get forge-tongs: #{db.get("forge-tongs").inspect}"

view.close
db.close
FileUtils.rm_rf(path)
puts "snapshot demo complete"
