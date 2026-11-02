require "./spec_helper"

describe "Cinderstore compaction budgets" do
  it "bounds a slice and resumes it after restart" do
    config = Cinderstore::SpecHelpers.fast_config
    config.compaction_work_budget = 2
    Cinderstore::SpecHelpers.with_db_path("compact-budget-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      db.put("a", "old")
      db.put("b", "keep")
      db.put("gone", "old")
      db.flush
      db.put("a", "new")
      db.delete("b")
      db.delete("gone")
      db.put("c", "fresh")
      db.flush

      snapshot = db.snapshot
      db.compact
      db.compaction_pending?.should be_true
      db.scan.map(&.[0]).should eq(%w[a c])
      snapshot.scan.map(&.[0]).should eq(%w[a c])
      snapshot.release
      db.close

      slices = 1
      loop do
        db = Cinderstore::DB.new(path, config)
        break unless db.compaction_pending?
        db.compact
        slices += 1
        db.close
      end

      slices.should be > 1
      db.scan.map { |key, value| {key, value} }.should eq([
        {"a", "new"},
        {"c", "fresh"},
      ])
      db.get("b").should be_nil
      db.get("gone").should be_nil
      db.stats.l0.should eq(0)
      db.stats.entries.should eq(2)
      db.close
    end
  end

  it "matches an uninterrupted merge, including tombstone removal" do
    budgeted_config = Cinderstore::SpecHelpers.fast_config
    budgeted_config.compaction_work_budget = 2
    full_config = Cinderstore::SpecHelpers.fast_config
    Cinderstore::SpecHelpers.with_db_path("compact-budget-compare") do |budgeted_path|
      Cinderstore::SpecHelpers.with_db_path("compact-full-compare") do |full_path|
        budgeted = seed_budget_workload(budgeted_path, budgeted_config)
        uninterrupted = seed_budget_workload(full_path, full_config)
        uninterrupted.compact
        expected = uninterrupted.scan.map { |key, value| {key, value} }
        uninterrupted.close

        budgeted.compact
        budgeted.close
        loop do
          budgeted = Cinderstore::DB.new(budgeted_path, budgeted_config)
          break unless budgeted.compaction_pending?
          budgeted.compact
          budgeted.close
        end

        budgeted.scan.map { |key, value| {key, value} }.should eq(expected)
        budgeted.get("deleted").should be_nil
        budgeted.get("updated").should eq("new")
        budgeted.close
      end
    end
  end
end

private def seed_budget_workload(path : String, config : Cinderstore::DB::Config) : Cinderstore::DB
  db = Cinderstore::DB.new(path, config)
  db.put("deleted", "old")
  db.put("keep", "same")
  db.put("updated", "old")
  db.flush
  db.delete("deleted")
  db.put("updated", "new")
  db.put("fresh", "value")
  db.flush
  db
end
