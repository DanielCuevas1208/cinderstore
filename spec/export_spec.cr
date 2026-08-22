require "./spec_helper"

describe Cinderstore::DB do
  it "exports a consistent primary-key view to a new database" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("db-export") do |source_path|
      destination = Cinderstore::SpecHelpers.tmp_db_path("db-export-copy")
      source = Cinderstore::DB.new(source_path, config)
      begin
        source.put("alpha", "one")
        source.put("beta", "two")
        source.delete("hidden")

        copied = source.export(destination, config)

        copied.should eq(2)
        exported = Cinderstore::DB.new(destination, config)
        begin
          exported.scan.should eq([{"alpha", "one"}, {"beta", "two"}])
          exported.stats.entries.should eq(2)
        ensure
          exported.close
        end
      ensure
        source.close
        FileUtils.rm_rf(destination)
      end
    end
  end

  it "exports only snapshot rows while the source keeps its indexes" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("db-export-index") do |source_path|
      destination = Cinderstore::SpecHelpers.tmp_db_path("db-export-index-copy")
      source = Cinderstore::DB.new(source_path, config)
      begin
        source.create_json_index("by-kind", "kind")
        source.put("a", %({"kind":"tool"}))
        source.put("b", %({"kind":"part"}))

        source.export(destination, config).should eq(2)

        exported = Cinderstore::DB.new(destination, config)
        begin
          exported.scan.map(&.[0]).should eq(%w[a b])
          exported.stats.entries.should eq(2)
        ensure
          exported.close
        end
      ensure
        source.close
        FileUtils.rm_rf(destination)
      end
    end
  end

  it "does not overwrite an existing export destination" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("db-export-existing") do |source_path|
      destination = Cinderstore::SpecHelpers.tmp_db_path("db-export-existing-copy")
      Dir.mkdir_p(destination)
      source = Cinderstore::DB.new(source_path, config)
      begin
        expect_raises(Cinderstore::Error, /export destination already exists/) do
          source.export(destination, config)
        end
      ensure
        source.close
        FileUtils.rm_rf(destination)
      end
    end
  end

  it "auto flushes tombstones when deletes fill the memtable" do
    config = Cinderstore::SpecHelpers.small_config(memtable_limit: 500)
    Cinderstore::SpecHelpers.with_db("db-delete-autoflush", config) do |db, _path|
      7.times { |i| db.put("k#{i}", "value") }
      db.flush
      tables_before = db.stats.tables
      8.times { |i| db.delete("missing#{i}") }

      deadline = Time.instant + 5.seconds
      until db.stats.tables > tables_before
        raise "tombstone flush did not start" if Time.instant >= deadline
        sleep 10.milliseconds
      end
      db.scan.size.should eq(7)
    end
  end
end
