require "./spec_helper"

private def mem_with(entries : Array(Cinderstore::Entry))
  mem = Cinderstore::MemTable.new
  entries.each { |e| e.alive ? mem.put(e.key, e.value, e.seq) : mem.delete(e.key, e.seq) }
  mem
end

describe Cinderstore::MemIter do
  it "iterates from a seek key" do
    mem = mem_with([
      Cinderstore::Entry.new("a", 1_i64, true, "1"),
      Cinderstore::Entry.new("b", 2_i64, true, "2"),
      Cinderstore::Entry.new("c", 3_i64, true, "3"),
    ])
    iter = Cinderstore::MemIter.new(mem, "b")
    keys = [] of String
    while e = iter.next?
      keys << e.key
    end
    keys.should eq(%w[b c])
  end

  it "reseek restarts iteration" do
    mem = mem_with([
      Cinderstore::Entry.new("a", 1_i64, true, "1"),
      Cinderstore::Entry.new("b", 2_i64, true, "2"),
      Cinderstore::Entry.new("c", 3_i64, true, "3"),
    ])
    iter = Cinderstore::MemIter.new(mem)
    iter.next?.should_not be_nil
    iter.seek("c")
    iter.next?.not_nil!.key.should eq("c")
  end
end

describe Cinderstore::TableIter do
  it "seeks into the middle of a multi-block table" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("iter")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000009.sst")
    entries = 600.times.map { |i| Cinderstore::Entry.new("key-%04d" % i, i.to_i64, true, "v#{i}") }.to_a
    File.open(path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 9_i64, 64, 0.01)
      entries.each { |e| writer.add(e.key, e.value, e.seq, e.alive) }
      writer.finish
    end

    reader = Cinderstore::SstableReader.new(path, 9_i64, nil)
    iter = Cinderstore::TableIter.new(reader, "key-0300")
    first = iter.next?
    first.not_nil!.key.should eq("key-0300")
    first.not_nil!.value.should eq("v300")
    count = 0
    while iter.next?
      count += 1
    end
    count.should eq(299)
    reader.close
  end

  it "seeks past the end of the table" do
    dir = Cinderstore::SpecHelpers.tmp_db_path("iter")
    Dir.mkdir_p(dir)
    path = File.join(dir, "000009.sst")
    File.open(path, "w") do |io|
      writer = Cinderstore::SstableWriter.new(io, 9_i64, 64, 0.01)
      10.times { |i| writer.add("k#{i}", "v", i.to_i64, true) }
      writer.finish
    end
    reader = Cinderstore::SstableReader.new(path, 9_i64, nil)
    iter = Cinderstore::TableIter.new(reader, "zzz")
    iter.next?.should be_nil
    reader.close
  end
end

describe Cinderstore::MergeIter do
  it "merges two sorted streams in order" do
    a = Cinderstore::MemIter.new(mem_with([
      Cinderstore::Entry.new("a", 1_i64, true, "a1"),
      Cinderstore::Entry.new("c", 3_i64, true, "c3"),
    ]))
    b = Cinderstore::MemIter.new(mem_with([
      Cinderstore::Entry.new("b", 2_i64, true, "b2"),
      Cinderstore::Entry.new("d", 4_i64, true, "d4"),
    ]))
    iter = Cinderstore::MergeIter.new([a, b])
    keys = [] of String
    while e = iter.next?
      keys << e.key
    end
    keys.should eq(%w[a b c d])
  end

  it "keeps the newest entry when keys overlap" do
    a = Cinderstore::MemIter.new(mem_with([
      Cinderstore::Entry.new("k", 5_i64, true, "newer"),
    ]))
    b = Cinderstore::MemIter.new(mem_with([
      Cinderstore::Entry.new("k", 2_i64, true, "older"),
    ]))
    iter = Cinderstore::MergeIter.new([a, b])
    first = iter.next?
    first.not_nil!.key.should eq("k")
    first.not_nil!.value.should eq("newer")
    iter.next?.should be_nil
  end

  it "yields a tombstone when the newest entry is a tombstone" do
    a = Cinderstore::MemIter.new(mem_with([
      Cinderstore::Entry.new("k", 6_i64, false, ""),
    ]))
    b = Cinderstore::MemIter.new(mem_with([
      Cinderstore::Entry.new("k", 3_i64, true, "old"),
    ]))
    iter = Cinderstore::MergeIter.new([a, b])
    first = iter.next?
    first.not_nil!.alive.should be_false
    iter.next?.should be_nil
  end

  it "deduplicates across three streams" do
    streams = [
      Cinderstore::MemIter.new(mem_with([
        Cinderstore::Entry.new("a", 1_i64, true, "a1"),
        Cinderstore::Entry.new("c", 3_i64, true, "c3"),
      ])),
      Cinderstore::MemIter.new(mem_with([
        Cinderstore::Entry.new("a", 4_i64, true, "a4"),
        Cinderstore::Entry.new("b", 2_i64, true, "b2"),
      ])),
      Cinderstore::MemIter.new(mem_with([
        Cinderstore::Entry.new("b", 5_i64, true, "b5"),
        Cinderstore::Entry.new("c", 6_i64, true, "c6"),
      ])),
    ]
    iter = Cinderstore::MergeIter.new(streams)
    results = [] of String
    while e = iter.next?
      results << "#{e.key}=#{e.value}"
    end
    results.should eq(["a=a4", "b=b5", "c=c6"])
  end

  it "supports seek across all streams" do
    a = Cinderstore::MemIter.new(mem_with([
      Cinderstore::Entry.new("a", 1_i64, true, "a1"),
      Cinderstore::Entry.new("d", 4_i64, true, "d4"),
    ]))
    b = Cinderstore::MemIter.new(mem_with([
      Cinderstore::Entry.new("b", 2_i64, true, "b2"),
      Cinderstore::Entry.new("e", 5_i64, true, "e5"),
    ]))
    iter = Cinderstore::MergeIter.new([a, b])
    iter.seek("b")
    keys = [] of String
    while e = iter.next?
      keys << e.key
    end
    keys.should eq(%w[b d e])
  end
end

describe Cinderstore::LiveIter do
  it "filters out tombstones" do
    inner = Cinderstore::MemIter.new(mem_with([
      Cinderstore::Entry.new("a", 1_i64, true, "1"),
      Cinderstore::Entry.new("b", 2_i64, false, ""),
      Cinderstore::Entry.new("c", 3_i64, true, "3"),
    ]))
    iter = Cinderstore::LiveIter.new(inner)
    keys = [] of String
    while e = iter.next?
      keys << e.key
    end
    keys.should eq(%w[a c])
  end
end
