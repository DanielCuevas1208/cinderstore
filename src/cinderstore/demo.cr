require "file_utils"

module Cinderstore
  # A self-contained walkthrough of the store.
  #
  # The demo loads a small product catalog, writes it, scans a range,
  # flushes, compacts, and verifies recovery. Its output is deterministic.
  # Set `checksums` to false to run the walkthrough in fast mode.
  class Demo
    def self.run(db_path : String? = nil, fixture : String? = nil, checksums : Bool = true) : Int32
      new(db_path, fixture, checksums).run
    end

    def initialize(@db_path : String? = nil, @fixture : String? = nil, @checksums : Bool = true)
    end

    def run : Int32
      path = @db_path || File.join(Dir.tempdir, "cinderstore-demo")
      FileUtils.rm_rf(path) if File.exists?(path)
      fixture_path = resolve_fixture
      raise Error.new("fixture not found: #{fixture_path}") unless File.exists?(fixture_path)

      rows = load_fixture(fixture_path)
      raise Error.new("fixture is empty") if rows.empty?

      config = DB::Config.new
      config.sync_writes = false
      config.compact_on_flush = false
      config.checksums = @checksums
      db = DB.new(path, config)

      puts "== Cinderstore #{VERSION} demo =="
      puts ""
      puts "Loaded #{rows.size} products from #{fixture_path}"
      puts "Database directory: #{path}"
      puts ""

      rows.each do |sku, name, price, stock|
        db.put(sku, %({"name":"#{name}","price":#{price},"stock":#{stock}}))
      end

      puts "1. Writes buffered in the memtable"
      puts "   entries: #{db.stats.entries}, memtable bytes: #{db.stats.memtable_bytes}, tables: #{db.stats.tables}"
      puts ""

      puts "2. Range scan SKU-0010 to SKU-0020"
      db.scan("SKU-0010", "SKU-0020", 5).each do |key, value|
        puts "   #{key}  #{value}"
      end
      puts "   ... (#{db.stats.entries} rows in the store)"
      puts ""

      puts "3. Flush memtable to a sorted table"
      db.flush
      print_stats(db)
      puts ""

      puts "4. Delete 4 products, update 2 products, then flush again"
      %w[SKU-0003 SKU-0007 SKU-0012 SKU-0019].each { |sku| db.delete(sku) }
      db.put("SKU-0001", %({"name":"Forge Anvil 45kg","price":175.00,"stock":14}))
      db.put("SKU-0010", %({"name":"Ash Rake Forged","price":15.50,"stock":29}))
      db.flush
      print_stats(db)
      puts "   The deleted keys still occupy space in the level-0 tables."
      puts ""

      puts "5. Compact merges the tables and drops the deleted keys"
      db.compact
      print_stats(db)
      puts "   The store keeps the newest value for each key."
      puts ""

      puts "6. Verify deletes and updates after compaction"
      puts "   get SKU-0003 => #{db.get("SKU-0003").inspect}"
      puts "   get SKU-0001 => #{db.get("SKU-0001").inspect}"
      puts "   scan count   => #{db.scan.size}"
      puts ""

      puts "7. Snapshot the store for a consistent read"
      snap = db.snapshot
      puts "   snapshot rows at creation: #{snap.count}"
      db.put("SKU-0025", %({"name":"Bellows Copper","price":48.50,"stock":9}))
      db.put("SKU-0026", %({"name":"Chimney Brush Steel","price":23.90,"stock":17}))
      db.delete("SKU-0001")
      db.flush
      puts "   after 2 new writes and 1 delete, then a flush"
      puts "   live rows: #{db.scan.size}, snapshot rows: #{snap.count}"
      puts "   live SKU-0001    => #{db.get("SKU-0001").inspect}"
      puts "   snapshot SKU-0001 => #{snap.get("SKU-0001").inspect}"
      puts "   snapshot iterator SKU-0010 to SKU-0016"
      keys = [] of String
      iter = snap.iter("SKU-0010")
      while (entry = iter.next?) && entry.key < "SKU-0016"
        keys << entry.key
      end
      puts "   #{keys.join(", ")}"
      snap.release
      puts ""

      db.close

      puts "8. Reopen the database and verify recovery"
      reopened = DB.new(path, config)
      count = reopened.scan.size
      puts "   rows after restart: #{count}"
      reopened.close
      puts ""

      puts "9. Fast mode skips checksums"
      ref_config = DB::Config.new
      ref_config.sync_writes = false
      ref_config.compact_on_flush = false
      ref_config.checksums = true
      fast_config = DB::Config.new
      fast_config.sync_writes = false
      fast_config.compact_on_flush = false
      fast_config.checksums = false
      ref_path = "#{path}-ref"
      fast_path = "#{path}-fast"
      FileUtils.rm_rf(ref_path) if File.exists?(ref_path)
      FileUtils.rm_rf(fast_path) if File.exists?(fast_path)
      ref_db = DB.new(ref_path, ref_config)
      fast_db = DB.new(fast_path, fast_config)
      rows.each do |sku, name, price, stock|
        value = %({"name":"#{name}","price":#{price},"stock":#{stock}})
        ref_db.put(sku, value)
        fast_db.put(sku, value)
      end
      ref_db.flush
      fast_db.flush
      puts "   checksummed disk bytes: #{ref_db.stats.disk_bytes}"
      puts "   fast disk bytes:        #{fast_db.stats.disk_bytes}"
      puts "   fast mode saves #{ref_db.stats.disk_bytes - fast_db.stats.disk_bytes} bytes on disk"
      puts "   fast mode scan count: #{fast_db.scan.size}"
      snap = fast_db.snapshot
      puts "   fast mode snapshot rows: #{snap.count}"
      snap.release
      ref_db.close
      fast_db.close
      fast_reopened = DB.new(fast_path, fast_config)
      puts "   fast mode rows after restart: #{fast_reopened.scan.size}"
      fast_reopened.close
      FileUtils.rm_rf(ref_path) rescue nil
      FileUtils.rm_rf(fast_path) rescue nil
      puts ""

      puts "Demo complete."
      0
    end

    private def print_stats(db : DB) : Nil
      stats = db.stats
      puts "   tables: #{stats.tables} (l0: #{stats.l0}, l1: #{stats.l1}), entries: #{stats.entries}"
      puts "   disk bytes: #{stats.disk_bytes}, memtable bytes: #{stats.memtable_bytes}"
    end

    private def resolve_fixture : String
      candidates = [
        File.expand_path("../../fixtures/catalog.csv", __FILE__),
        File.join(Dir.current, "fixtures", "catalog.csv"),
      ]
      candidates.each do |candidate|
        return candidate if File.exists?(candidate)
      end
      candidates.first
    end

    private def load_fixture(path : String) : Array(Tuple(String, String, String, String))
      rows = [] of Tuple(String, String, String, String)
      File.each_line(path) do |line|
        line = line.strip
        next if line.empty? || line.starts_with?("#")
        next if line == "sku,name,price,stock"
        fields = line.split(",")
        next if fields.size < 4
        rows << {fields[0].strip, fields[1].strip, fields[2].strip, fields[3].strip}
      end
      rows
    end
  end
end
