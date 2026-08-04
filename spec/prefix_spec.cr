require "./spec_helper"

describe Cinderstore::DB do
  it %q(streams keys with a prefix and applies a limit after filtering) do
    Cinderstore::SpecHelpers.with_db(%q(scan-prefix), Cinderstore::SpecHelpers.fast_config) do |db, _path|
      %w[SKU-0010 SKU-0011 SKU-0020 SKU-0012].each { |key| db.put(key, key) }

      db.scan_prefix(%q(SKU-001), 2).map(&.[0]).should eq(%w[SKU-0010 SKU-0011])
      db.scan_prefix(%q()).map(&.[0]).should eq(%w[SKU-0010 SKU-0011 SKU-0012 SKU-0020])
      iter = db.scan_prefix_iter(%q(SKU-001))
      iter.to_a.map(&.[0]).should eq(%w[SKU-0010 SKU-0011 SKU-0012])
      iter.close
    end
  end

  it %q(keeps a snapshot prefix stable across writes) do
    Cinderstore::SpecHelpers.with_db(%q(scan-prefix-snapshot)) do |db, _path|
      db.put(%q(user:1), %q(old))
      snapshot = db.snapshot
      db.put(%q(user:2), %q(new))
      db.delete(%q(user:1))

      snapshot.scan_prefix(%q(user:)).should eq([{"user:1", "old"}])
      iter = snapshot.scan_prefix_iter(%q(user:))
      iter.to_a.should eq([{"user:1", "old"}])
      iter.close
      snapshot.release
    end
  end
end

describe Cinderstore::Util do
  it %q(computes a byte upper bound for a prefix) do
    Cinderstore::Util.prefix_end(%q(SKU-001)).should eq(%q(SKU-002))
    Cinderstore::Util.prefix_end(%q()).should be_nil
  end
end
