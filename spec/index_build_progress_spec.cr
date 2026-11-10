require "./spec_helper"

describe "Cinderstore index build progress" do
  it "persists progress and keeps incomplete queries unavailable" do
    config = Cinderstore::SpecHelpers.fast_config
    config.index_build_batch_size = 2
    Cinderstore::SpecHelpers.with_db_path("index-build-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      %w[a b c d e].each_with_index do |key, index|
        db.put(key, %({"kind":"kind-#{index % 2}"}))
      end
      db.flush

      status = db.start_json_index("by-kind", "kind")
      status.ready?.should be_false
      status.processed.should eq(0_i64)
      expect_raises(Cinderstore::IndexNotReadyError) { db.query("by-kind", "kind-0") }
      snapshot = db.snapshot
      expect_raises(Cinderstore::IndexNotReadyError) { snapshot.query("by-kind", "kind-0") }
      snapshot.release

      status = db.build_index("by-kind")
      status.processed.should eq(2_i64)
      status.ready?.should be_false
      db.close

      db = Cinderstore::DB.new(path, config)
      resumed = db.index_build_status("by-kind").not_nil!
      resumed.processed.should eq(2_i64)
      resumed.ready?.should be_false
      expect_raises(Cinderstore::IndexNotReadyError) { db.query("by-kind", "kind-0") }

      until resumed.ready?
        resumed = db.build_index("by-kind")
      end
      db.query("by-kind", "kind-0").should eq(%w[a c e])
      resumed.last_key.should eq("e")
      db.close
    end
  end

  it "keeps the finished index equal to a primary scan after concurrent writes" do
    config = Cinderstore::SpecHelpers.fast_config
    config.index_build_batch_size = 2
    Cinderstore::SpecHelpers.with_db("index-build-writes", config) do |db, _path|
      %w[a b c d e].each do |key|
        db.put(key, %({"kind":"red"}))
      end
      db.flush
      db.start_json_index("by-kind", "kind")
      db.build_index("by-kind").ready?.should be_false

      db.put("a", %({"kind":"blue"}))
      db.put("z", %({"kind":"red"}))

      status = db.index_build_status("by-kind").not_nil!
      until status.ready?
        status = db.build_index("by-kind")
      end

      expected = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
      db.scan.each do |key, value|
        kind = JSON.parse(value)["kind"].as_s
        expected[kind] << key
      end
      expected.each_value { |keys| keys.sort! }
      db.query("by-kind", "blue").should eq(expected["blue"])
      db.query("by-kind", "red").should eq(expected["red"])
      db.index_build_status("by-kind").not_nil!.ready?.should be_true
    end
  end
end
