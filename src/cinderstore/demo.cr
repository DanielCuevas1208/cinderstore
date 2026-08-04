require "file_utils"

module Cinderstore
  # A self-contained walkthrough of the store.
  #
  # The demo loads a small product catalog, writes it, scans a range,
  # flushes, compacts, and verifies recovery. Its output is deterministic.
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

      catalog = load_fixture(fixture_path)
      raise Error.new("fixture is empty") if catalog.empty?

      config = DB::Config.new
      config.sync_writes = false
      config.compact_on_flush = false
      config.checksums = @checksums
      db = DB.new(path, config)

      puts "== Cinderstore #{VERSION} demo =="
      puts ""
      puts "Loaded #{catalog.size} products from #{fixture_path}"
      puts "Database directory: #{path}"
      puts ""

      catalog.each do |sku, name, price, stock|
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
      rows = [] of String
      iter = snap.iter("SKU-0010")
      while (entry = iter.next?) && entry.key < "SKU-0016"
        rows << entry.key
      end
      puts "   #{rows.join(", ")}"
      snap.release
      puts ""

      db.close

      puts "8. Reopen the database and verify recovery"
      reopened = DB.new(path, config)
      count = reopened.scan.size
      puts "   rows after restart: #{count}"
      reopened.close
      puts ""

      puts "9. Leveled compaction keeps each level within its target"
      levels_path = File.join(Dir.tempdir, "cinderstore-levels-demo")
      FileUtils.rm_rf(levels_path) if File.exists?(levels_path)
      levels_config = DB::Config.new
      levels_config.sync_writes = false
      levels_config.compact_on_flush = false
      levels_config.checksums = @checksums
      levels_config.memtable_limit = 2_000
      levels_config.l0_compact_threshold = 2
      levels_config.level_ratio = 2.0
      levels_config.max_levels = 5
      level_db = DB.new(levels_path, levels_config)
      5.times do |batch|
        20.times do |i|
          level_db.put("row-%d-%02d" % {batch, i}, "value-" + "x" * 40)
        end
        level_db.flush
      end
      puts "   after 5 flushes, level counts: #{level_db.stats.level_counts}"
      level_db.compact_levels
      puts "   after compact_levels:          #{level_db.stats.level_counts}"
      puts "   all #{level_db.scan.size} rows still readable"
      level_db.close
      puts ""

      puts "10. Fast mode skips checksums on new writes"
      checked_path = File.join(Dir.tempdir, "cinderstore-checked-demo")
      fast_path = File.join(Dir.tempdir, "cinderstore-fast-demo")
      FileUtils.rm_rf(checked_path) if File.exists?(checked_path)
      FileUtils.rm_rf(fast_path) if File.exists?(fast_path)
      checked = write_mode_demo(checked_path, catalog, true)
      fast = write_mode_demo(fast_path, catalog, false)
      puts "   checksummed: wal #{checked[0]} bytes, disk #{checked[1]} bytes"
      puts "   fast mode:   wal #{fast[0]} bytes, disk #{fast[1]} bytes"
      reopened = DB.new(fast_path)
      puts "   all #{reopened.scan.size} rows readable after a fast-mode restart"
      reopened.close
      puts ""

      puts "Demo complete."
      0
    end

    # Writes the catalog into a fresh database and reports the file sizes.
    #
    # The catalog is written three times so the checksums produce a clear
    # byte difference. The return value is the WAL size before the flush
    # and the table size after it.
    private def write_mode_demo(db_path : String, rows : Array(Tuple(String, String, String, String)),
                                checksums : Bool) : Tuple(Int64, Int64)
      config = DB::Config.new
      config.sync_writes = false
      config.compact_on_flush = false
      config.block_size = 128
      config.checksums = checksums
      db = DB.new(db_path, config)
      3.times do |round|
        rows.each do |sku, name, price, stock|
          db.put("%d-%s" % {round, sku}, %({"name":"#{name}","price":#{price},"stock":#{stock}}))
        end
      end
      wal_bytes = db.stats.wal_bytes
      db.flush
      disk_bytes = db.stats.disk_bytes
      db.close
      {wal_bytes, disk_bytes}
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
