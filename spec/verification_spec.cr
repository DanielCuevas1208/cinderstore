require "./spec_helper"

describe Cinderstore::DB::VerificationReport do
  it "reports valid tables and write ahead logs" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db("verify-valid", config) do |db, _path|
      db.put("alpha", "one")
      db.put("beta", "two")

      before_flush = db.verify
      before_flush.valid?.should be_true
      before_flush.tables.should eq(0)
      before_flush.wal_files.should eq(1)
      before_flush.wal_records.should eq(2)

      db.flush
      report = db.verify
      report.valid?.should be_true
      report.tables.should eq(1)
      report.table_entries.should eq(2)
      report.wal_files.should eq(1)
      report.wal_records.should eq(0)
      report.bytes_checked.should be > 0
      report.to_h["valid"].should be_true
      report.to_json.should contain("table_entries")
    end
  end
end

describe Cinderstore::DB do
  it "reports a corrupt table block" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("verify-table") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("alpha", "one")
      db.flush
      db.close

      table_name = Dir.children(path).find { |name| name.ends_with?(".sst") }.not_nil!
      table_path = File.join(path, table_name)
      bytes = File.read(table_path).to_slice.dup
      bytes[0] = (bytes[0] ^ 0xFF).to_u8
      File.open(table_path, "w") { |io| io.write(bytes) }

      report = Cinderstore::DB.verify(path)
      report.valid?.should be_false
      report.errors.first.should contain(table_name)
    end
  end

  it "reports a manifest mismatch without changing the table" do
    config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("verify-manifest") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("alpha", "one")
      db.flush
      db.close

      manifest_path = File.join(path, Cinderstore::DB::MANIFEST_NAME)
      manifest = Cinderstore::Manifest.load(manifest_path)
      manifest.levels[0][0].count += 1
      manifest.save(manifest_path)

      report = Cinderstore::DB.verify(path)
      report.valid?.should be_false
      table_name = "#{Cinderstore::Util.file_stem(manifest.levels[0][0].id)}.sst"
      report.errors.should contain("#{table_name}: manifest metadata mismatch")
    end
  end
end

describe Cinderstore::Wal do
  it "rejects a checksum error during verification" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("verify-wal")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000001.wal")
    begin
      writer = Cinderstore::Wal::Writer.new(path, false)
      writer.append(Cinderstore::Entry.new("alpha", 1_i64, true, "one"))
      writer.close

      bytes = File.read(path).to_slice.dup
      bytes[bytes.size - 1] = (bytes[bytes.size - 1] ^ 0xFF).to_u8
      File.open(path, "w") { |io| io.write(bytes) }

      expect_raises(Cinderstore::CorruptDataError) { Cinderstore::Wal.verify(path) }
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
