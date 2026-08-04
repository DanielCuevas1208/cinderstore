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

      puts "11. Batch writes and group commit"
      batch_path = File.join(Dir.tempdir, "cinderstore-batch-demo")
      FileUtils.rm_rf(batch_path) if File.exists?(batch_path)
      batch_config = DB::Config.new
      batch_config.sync_writes = false
      batch_config.compact_on_flush = false
      batch_db = DB.new(batch_path, batch_config)
      batch_db.write do |b|
        catalog.each do |sku, name, price, stock|
          b.put(sku, %({"name":"#{name}","price":#{price},"stock":#{stock}}))
        end
      end
      puts "   one batch wrote #{batch_db.scan.size} rows as 1 write operation"
      puts "   sequence after the batch: #{batch_db.stats.seq}"
      batch_db.close
      reopened = DB.new(batch_path)
      puts "   all #{reopened.scan.size} rows recovered after a restart"
      reopened.close
      puts ""

      group_path = File.join(Dir.tempdir, "cinderstore-group-demo")
      FileUtils.rm_rf(group_path) if File.exists?(group_path)
      group_config = DB::Config.new
      group_config.sync_writes = true
      group_config.compact_on_flush = false
      group_config.memtable_limit = 1_i64 << 30
      group_db = DB.new(group_path, group_config)
      done = Channel(Nil).new
      8.times do |i|
        spawn do
          25.times do |j|
            group_db.put("grow-%d-%02d" % {i, j}, "value-%d" % j)
          end
          done.send(nil)
        end
      end
      8.times { done.receive }
      puts "   concurrent writes: #{group_db.stats.writes}, durability commits: #{group_db.stats.commits}"
      group_db.close
      reopened = DB.new(group_path)
      puts "   all #{reopened.scan.size} rows recovered after a restart"
      reopened.close
      puts ""

      puts "12. Secondary indexes track derived views"
      index_path = File.join(Dir.tempdir, "cinderstore-index-demo")
      FileUtils.rm_rf(index_path) if File.exists?(index_path)
      index_config = DB::Config.new
      index_config.sync_writes = false
      index_config.compact_on_flush = false
      index_db = DB.new(index_path, index_config)
      index_db.create_json_index("by-name", "name")
      index_db.create_json_index("by-price", "price")
      index_db.create_json_index("by-stock", "stock")
      catalog.each do |sku, name, price, stock|
        index_db.put(sku, %({"name":"#{name}","price":#{price},"stock":#{stock}}))
      end
      index_db.flush
      puts "   created indexes on name, price, and stock"
      puts "   query by-name \"Ash Rake Forged\"  => #{format_keys(index_db.query("by-name", "Ash Rake Forged"))}"
      puts "   query by-price \"14.0\"            => #{format_keys(index_db.query("by-price", "14.0"))}"
      puts "   query by-stock \"31\"              => #{format_keys(index_db.query("by-stock", "31"))}"
      puts "   stock range 20 to 30               => #{format_keys(index_db.query_range("by-stock", "20", "30"))}"
      index_db.put("SKU-0010", %({"name":"Ash Rake Forged","price":15.50,"stock":31}))
      index_db.flush
      index_db.compact
      puts "   update SKU-0010 price to 15.50, then flush and compact"
      puts "   query by-price \"14.0\"            => #{format_keys(index_db.query("by-price", "14.0"))}"
      puts "   query by-price \"15.5\"            => #{format_keys(index_db.query("by-price", "15.5"))}"
      index_db.delete("SKU-0011")
      index_db.flush
      index_db.compact
      puts "   delete SKU-0011, then flush and compact"
      puts "   query by-name \"Coal Shovel Small\" => #{format_keys(index_db.query("by-name", "Coal Shovel Small"))}"
      puts ""

      puts "13. Streaming iterators for secondary index queries"
      streamed = [] of String
      iter = index_db.query_iter("by-price", "15.5")
      while key = iter.next?
        streamed << key
      end
      iter.close
      puts "   streamed by-price \"15.5\"            => #{format_keys(streamed)}"
      taken = [] of String
      qiter = index_db.query_range_iter("by-stock", "20", "30")
      while key = qiter.next?
        taken << key
        break if taken.size >= 3
      end
      qiter.close
      puts "   stock range 20 to 30, first 3        => #{format_keys(taken)}"
      snap = index_db.snapshot
      index_db.delete("SKU-0012")
      siter = snap.query_iter("by-name", "Ember Tray Brass")
      puts "   snapshot stream \"Ember Tray Brass\"  => #{format_keys(siter.to_a)}"
      siter.close
      puts "   live query after the delete          => #{format_keys(index_db.query("by-name", "Ember Tray Brass"))}"
      snap.release
      index_db.close
      reopened = DB.new(index_path)
      puts "   reopen and query by-stock \"31\"    => #{format_keys(reopened.query("by-stock", "31"))}"
      puts "14. Streaming primary-key range scans"
      range_keys = [] of String
      range_iter = reopened.scan_iter("SKU-0010", "SKU-0016")
      range_iter.each { |key, _value| range_keys << key }
      range_iter.close
      puts "   primary range SKU-0010 to SKU-0016 => #{format_keys(range_keys)}"
      range_snapshot = reopened.snapshot
      reopened.delete("SKU-0010")
      snapshot_range_keys = [] of String
      snapshot_range_iter = range_snapshot.scan_iter("SKU-0010", "SKU-0016")
      snapshot_range_iter.each { |key, _value| snapshot_range_keys << key }
      snapshot_range_iter.close
      range_snapshot.release
      puts "   snapshot still sees SKU-0010     => #{format_keys(snapshot_range_keys)}"
      reopened.close
      puts ""

      puts "Demo complete."
      0
    end

    # Formats a query result for the demo output.
    private def format_keys(keys : Array(String)) : String
      keys.empty? ? "(none)" : keys.join(", ")
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
