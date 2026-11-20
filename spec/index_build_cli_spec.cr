require "./spec_helper"
require "../src/cinderstore/cli"

module Cinderstore::SpecHelpers
  @@cli_built = false
  CLI_ROOT = File.expand_path("..", __DIR__)

  def self.ensure_cli_built
    return if @@cli_built
    status = Process.run("shards", ["build", "--production"], chdir: CLI_ROOT)
    raise "failed to build CLI" unless status.success?
    @@cli_built = true
  end

  def self.cli_binary : String
    {% if flag?(:win32) %}
      File.join(CLI_ROOT, "bin", "cinderstore.exe")
    {% else %}
      File.join(CLI_ROOT, "bin", "cinderstore")
    {% end %}
  end

  def self.run_cli(args : Array(String)) : Tuple(Int32, String, String)
    ensure_cli_built
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run(cli_binary, args, output: stdout, error: stderr, chdir: CLI_ROOT)
    code = status.try(&.exit_code) || 1
    {code, stdout.to_s.strip, stderr.to_s.strip}
  end

  def self.parse_index_status(output : String) : Hash(String, JSON::Any)
    JSON.parse(output).as_h.transform_values { |value| value }
  end
end

describe "Cinderstore index build CLI" do
  it "reports status fields and non-ready exit codes while building" do
    config = Cinderstore::SpecHelpers.fast_config
    config.index_build_batch_size = 2
    Cinderstore::SpecHelpers.with_db_path("index-cli-status") do |path|
      db = Cinderstore::DB.new(path, config)
      %w[a b c d].each_with_index do |key, index|
        db.put(key, %({"kind":"kind-#{index % 2}"}))
      end
      db.flush
      db.start_json_index("by-kind", "kind")
      db.close

      status_code, status_out, _stderr = Cinderstore::SpecHelpers.run_cli(
        ["index-status", "--db", path, "--index", "by-kind"])
      status_code.should eq(Cinderstore::CLI::BUILDING_EXIT)
      status = Cinderstore::SpecHelpers.parse_index_status(status_out)
      status["name"].as_s.should eq("by-kind")
      status["state"].as_s.should eq("building")
      status["processed"].as_i64.should eq(0_i64)
      status["last_key"].as_s.should eq("")
      status["ready"].as_bool.should be_false

      build_code, build_out, _build_err = Cinderstore::SpecHelpers.run_cli(
        ["index-build", "--db", path, "--index", "by-kind", "--batch-size", "2"])
      build_code.should eq(Cinderstore::CLI::BUILDING_EXIT)
      built = Cinderstore::SpecHelpers.parse_index_status(build_out)
      built["processed"].as_i64.should eq(2_i64)
      built["ready"].as_bool.should be_false

      query_code, _query_out, query_err = Cinderstore::SpecHelpers.run_cli(
        ["query", "--db", path, "--index", "by-kind", "--key", "kind-0"])
      query_code.should eq(Cinderstore::CLI::BUILDING_EXIT)
      query_err.should contain("still building")

      finished = false
      4.times do
        code, build_output, _err = Cinderstore::SpecHelpers.run_cli(
          ["index-build", "--db", path, "--index", "by-kind", "--batch-size", "2"])
        payload = Cinderstore::SpecHelpers.parse_index_status(build_output)
        if payload["ready"].as_bool
          finished = true
          code.should eq(0)
          break
        end
        code.should eq(Cinderstore::CLI::BUILDING_EXIT)
      end
      finished.should be_true

      Cinderstore::SpecHelpers.run_cli(
        ["query", "--db", path, "--index", "by-kind", "--key", "kind-0"])[0].should eq(0)
    end
  end

  it "resumes a build after reopen and matches library query gating" do
    config = Cinderstore::SpecHelpers.fast_config
    config.index_build_batch_size = 2
    Cinderstore::SpecHelpers.with_db_path("index-cli-restart") do |path|
      db = Cinderstore::DB.new(path, config)
      %w[a b c].each { |key| db.put(key, %({"kind":"red"})) }
      db.flush
      db.close

      start_code, start_out, _start_err = Cinderstore::SpecHelpers.run_cli(
        ["index-start", "--db", path, "--index", "by-kind", "--field", "kind", "--batch-size", "2"])
      start_code.should eq(Cinderstore::CLI::BUILDING_EXIT)
      started = Cinderstore::SpecHelpers.parse_index_status(start_out)
      started["state"].as_s.should eq("building")

      build_code, _, _ = Cinderstore::SpecHelpers.run_cli(
        ["index-build", "--db", path, "--index", "by-kind", "--batch-size", "2"])
      build_code.should eq(Cinderstore::CLI::BUILDING_EXIT)

      db = Cinderstore::DB.new(path, config)
      expect_raises(Cinderstore::IndexNotReadyError) { db.query("by-kind", "red") }
      db.close

      final_code, final_out, _ = Cinderstore::SpecHelpers.run_cli(
        ["index-build", "--db", path, "--index", "by-kind", "--batch-size", "2"])
      final = Cinderstore::SpecHelpers.parse_index_status(final_out)
      if final["ready"].as_bool
        final_code.should eq(0)
      else
        final_code.should eq(Cinderstore::CLI::BUILDING_EXIT)
        final_code, final_out, _ = Cinderstore::SpecHelpers.run_cli(
          ["index-build", "--db", path, "--index", "by-kind", "--batch-size", "2"])
        final = Cinderstore::SpecHelpers.parse_index_status(final_out)
        final_code.should eq(0)
        final["ready"].as_bool.should be_true
      end

      final["last_key"].as_s.should eq("c")
      Cinderstore::SpecHelpers.run_cli(
        ["query", "--db", path, "--index", "by-kind", "--key", "red"])[0].should eq(0)
    end
  end
end
