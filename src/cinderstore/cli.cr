require "option_parser"
require "json"
require "../cinderstore"

module Cinderstore
  # Command line interface for Cinderstore.
  class CLI
    BUILDING_EXIT = 2

    def self.run(args : Array(String)) : Int32
      new.run(args)
    end

    def run(args : Array(String)) : Int32
      command = args.first?
      unless command
        print_help
        return 0
      end

      case command
      when "server"        then run_server(args[1..])
      when "put"           then run_write(args[1..])
      when "get"           then run_read(args[1..])
      when "del", "delete" then run_delete(args[1..])
      when "scan"          then run_scan(args[1..])
      when "query"         then run_query(args[1..])
      when "export"        then run_export(args[1..])
      when "stats"         then run_simple("stats", args[1..])
      when "flush"         then run_simple("flush", args[1..])
      when "compact"       then run_simple("compact", args[1..])
      when "verify"        then run_verify(args[1..])
      when "demo"          then run_demo(args[1..])
      when "index-start"   then run_index_start(args[1..])
      when "index-status"  then run_index_status(args[1..])
      when "index-build"   then run_index_build(args[1..])
      when "help", "--help", "-h"
        print_help
        0
      else
        STDERR.puts "Unknown command: #{command}"
        print_help
        1
      end
    end

    private def run_server(rest : Array(String)) : Int32
      db_path = "cinderstore-data"
      host = "127.0.0.1"
      port = 7654
      config = DB::Config.new
      index_specs = [] of Tuple(String, String)
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Database directory") { |v| db_path = v }
      parser.on("--host HOST", "Bind address") { |v| host = v }
      parser.on("--port PORT", "Listen on this port") { |v| port = v.to_i }
      parser.on("--no-checksums", "Skip checksums on new writes") { config.checksums = false }
      parser.on("--index SPEC", "JSON field index as name:field") { |v| index_specs << parse_index_spec(v) }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      db = DB.new(db_path, config)
      index_specs.each { |name, field| db.create_json_index(name, field) }
      server = Server.new(db, host, port)
      server.run
      db.close
      0
    end

    private def parse_index_spec(spec : String) : Tuple(String, String)
      name, field = spec.split(":", 2)
      raise Error.new("--index must be name:field") if field.nil? || name.empty? || field.empty?
      {name, field}
    end

    private def run_write(rest : Array(String)) : Int32
      db_path = "cinderstore-data"
      key = ""
      value = ""
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Database directory") { |v| db_path = v }
      parser.on("--key KEY", "Key to write") { |v| key = v }
      parser.on("--value VALUE", "Value to write") { |v| value = v }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      raise Error.new("missing --key") if key.empty?
      db = DB.new(db_path)
      begin
        db.put(key, value)
        puts "ok"
      ensure
        db.close
      end
      0
    end

    private def run_read(rest : Array(String)) : Int32
      db_path = "cinderstore-data"
      key = ""
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Database directory") { |v| db_path = v }
      parser.on("--key KEY", "Key to read") { |v| key = v }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      raise Error.new("missing --key") if key.empty?
      db = DB.new(db_path)
      begin
        if value = db.get(key)
          puts value
          0
        else
          puts "not found"
          1
        end
      ensure
        db.close
      end
    end

    private def run_delete(rest : Array(String)) : Int32
      db_path = "cinderstore-data"
      key = ""
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Database directory") { |v| db_path = v }
      parser.on("--key KEY", "Key to delete") { |v| key = v }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      raise Error.new("missing --key") if key.empty?
      db = DB.new(db_path)
      begin
        db.delete(key)
        puts "ok"
      ensure
        db.close
      end
      0
    end

    private def run_scan(rest : Array(String)) : Int32
      db_path = "cinderstore-data"
      start_key = ""
      finish_key = ""
      prefix : String? = nil
      limit = -1
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Database directory") { |v| db_path = v }
      parser.on("--start KEY", "First key (inclusive)") { |v| start_key = v }
      parser.on("--finish KEY", "Last key (exclusive)") { |v| finish_key = v }
      parser.on("--limit N", "Maximum rows") { |v| limit = v.to_i }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.on("--prefix PREFIX", "Keys that start with prefix") { |v| prefix = v }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      if prefix && (!start_key.empty? || !finish_key.empty?)
        raise Error.new("--prefix cannot be combined with --start or --finish")
      end
      db = DB.new(db_path)
      iter : ScanIter? = nil
      begin
        iter = if prefix
                 db.scan_prefix_iter(prefix.not_nil!, limit)
               else
                 db.scan_iter(start_key, finish_key.empty? ? nil : finish_key, limit)
               end
        stream = iter.not_nil!

        while pair = stream.next?
          puts "#{pair[0]}\t#{pair[1]}"
        end
      ensure
        iter.try { |value| value.close }
        db.close
      end
      0
    end

    private def run_query(rest : Array(String)) : Int32
      db_path = "cinderstore-data"
      index = ""
      key = ""
      start_key = ""
      finish_key = ""
      limit = -1
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Database directory") { |v| db_path = v }
      parser.on("--index NAME", "Index to query") { |v| index = v }
      parser.on("--key KEY", "Exact index key") { |v| key = v }
      parser.on("--start KEY", "First index key (inclusive)") { |v| start_key = v }
      parser.on("--finish KEY", "Last index key (exclusive)") { |v| finish_key = v }
      parser.on("--limit N", "Maximum rows") { |v| limit = v.to_i }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      raise Error.new("missing --index") if index.empty?
      db = DB.new(db_path)
      begin
        iter = if key.empty?
                 db.query_range_iter(index, start_key, finish_key.empty? ? nil : finish_key, limit)
               else
                 db.query_iter(index, key, limit)
               end
        while pk = iter.next?
          puts pk
        end
        iter.close
      rescue ex : IndexNotReadyError
        STDERR.puts "error: #{ex.message}"
        return BUILDING_EXIT
      ensure
        db.close
      end
      0
    end

    private def open_db(path : String, config : DB::Config = DB::Config.new) : DB
      DB.new(path, config)
    end

    private def print_index_status(status : DB::IndexBuildStatus) : Nil
      status.to_json(STDOUT)
      puts
    end

    private def run_index_start(rest : Array(String)) : Int32
      db_path = "cinderstore-data"
      name = ""
      field = ""
      batch_size = 0
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Database directory") { |v| db_path = v }
      parser.on("--index NAME", "Index name") { |v| name = v }
      parser.on("--field FIELD", "JSON field to index") { |v| field = v }
      parser.on("--batch-size N", "Rows per build_index batch") { |v| batch_size = v.to_i }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      raise Error.new("missing --index") if name.empty?
      raise Error.new("missing --field") if field.empty?
      config = DB::Config.new
      config.index_build_batch_size = batch_size if batch_size > 0
      db = open_db(db_path, config)
      begin
        print_index_status(db.start_json_index(name, field))
        BUILDING_EXIT
      ensure
        db.close
      end
    end

    private def run_index_status(rest : Array(String)) : Int32
      db_path = "cinderstore-data"
      name = ""
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Database directory") { |v| db_path = v }
      parser.on("--index NAME", "Index name") { |v| name = v }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      raise Error.new("missing --index") if name.empty?
      db = open_db(db_path)
      begin
        status = db.index_build_status(name)
        unless status
          STDERR.puts "error: unknown index: #{name}"
          return 1
        end
        print_index_status(status)
        status.ready? ? 0 : BUILDING_EXIT
      ensure
        db.close
      end
    end

    private def run_index_build(rest : Array(String)) : Int32
      db_path = "cinderstore-data"
      name = ""
      batch_size = 0
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Database directory") { |v| db_path = v }
      parser.on("--index NAME", "Index name") { |v| name = v }
      parser.on("--batch-size N", "Rows per build_index batch") { |v| batch_size = v.to_i }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      raise Error.new("missing --index") if name.empty?
      config = DB::Config.new
      config.index_build_batch_size = batch_size if batch_size > 0
      db = open_db(db_path, config)
      begin
        status = db.build_index(name)
        print_index_status(status)
        status.ready? ? 0 : BUILDING_EXIT
      rescue ex : InvalidIndexError
        STDERR.puts "error: #{ex.message}"
        1
      ensure
        db.close
      end
    end

    private def run_simple(action : String, rest : Array(String)) : Int32
      db_path = "cinderstore-data"
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Database directory") { |v| db_path = v }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      db = DB.new(db_path)
      begin
        case action
        when "stats"
          puts db.stats
        when "flush"
          db.flush
          puts "ok"
        when "compact"
          db.compact
          puts "ok"
        end
      ensure
        db.close
      end
      0
    end

    private def run_export(rest : Array(String)) : Int32
      db_path = "cinderstore-data"
      destination = ""
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Source database directory") { |v| db_path = v }
      parser.on("--output PATH", "New export directory") { |v| destination = v }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      raise Error.new("missing --output") if destination.empty?
      db = DB.new(db_path)
      begin
        rows = db.export(destination)
        puts "exported #{rows} rows to #{destination}"
      ensure
        db.close
      end
      0
    end

    private def run_verify(rest : Array(String)) : Int32
      db_path = "cinderstore-data"
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Database directory") { |v| db_path = v }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      report = DB.verify(db_path)
      puts report
      report.valid? ? 0 : 1
    end

    private def run_demo(rest : Array(String)) : Int32
      db_path = nil
      fixture = nil
      checksums = true
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Database directory") { |v| db_path = v }
      parser.on("--fixture PATH", "CSV fixture file") { |v| fixture = v }
      parser.on("--no-checksums", "Skip checksums on new writes") { checksums = false }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      Demo.run(db_path, fixture, checksums)
    end

    private def print_help : Nil
      puts <<-HELP
        Cinderstore #{VERSION} - an embeddable log structured merge tree.

        Usage: cinderstore <command> [options]

        Commands:
          server      Serve get, put, and delete over a local socket
          put         Write a key/value pair
          get         Read a value by key
          del         Delete a key
          scan        List keys in a range
          query       Find primary keys through a secondary index
          index-start Start a resumable JSON index build
          index-status  Show persisted JSON index build progress
          index-build   Run one JSON index build batch
          export      Copy a consistent snapshot to a new directory
          stats       Show database counters
          flush       Flush the memtable to a table
          compact     Merge tables and drop stale data
          verify      Check table and log integrity
          demo        Run a self-contained walkthrough
          help        Show this help

        Run "cinderstore <command> --help" for command options.
        HELP
    end
  end
end
