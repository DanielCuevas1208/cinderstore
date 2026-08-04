require "option_parser"
require "./cinderstore"

module Cinderstore
  # Command line interface for Cinderstore.
  class CLI
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
      when "stats"         then run_simple("stats", args[1..])
      when "flush"         then run_simple("flush", args[1..])
      when "compact"       then run_simple("compact", args[1..])
      when "demo"          then run_demo(args[1..])
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
      limit = -1
      help = false
      parser = OptionParser.new
      parser.on("--db PATH", "Database directory") { |v| db_path = v }
      parser.on("--start KEY", "First key (inclusive)") { |v| start_key = v }
      parser.on("--finish KEY", "Last key (exclusive)") { |v| finish_key = v }
      parser.on("--limit N", "Maximum rows") { |v| limit = v.to_i }
      parser.on("-h", "--help", "Show this help") { help = true }
      parser.parse(rest)
      if help
        puts parser
        return 0
      end
      db = DB.new(db_path)
      begin
        rows = db.scan(start_key, finish_key.empty? ? nil : finish_key, limit)
        rows.each do |key, value|
          puts "#{key}\t#{value}"
        end
      ensure
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
                 db.query_range_iter(index, start_key, finish_key.empty? ? nil : finish_key)
               else
                 db.query_iter(index, key)
               end
        count = 0
        while pk = iter.next?
          puts pk
          count += 1
          break if limit >= 0 && count >= limit
        end
        iter.close
      ensure
        db.close
      end
      0
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
          stats       Show database counters
          flush       Flush the memtable to a table
          compact     Merge tables and drop stale data
          demo        Run a self-contained walkthrough
          help        Show this help

        Run "cinderstore <command> --help" for command options.
        HELP
    end
  end
end

exit Cinderstore::CLI.run(ARGV)
