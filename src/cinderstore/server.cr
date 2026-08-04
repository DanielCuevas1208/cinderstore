require "socket"

module Cinderstore
  # A local TCP server that exposes get, put, and delete.
  #
  # Each client connection runs in its own fiber. Commands are newline
  # terminated. See the README for the full protocol reference.
  class Server
    # One parsed command from the wire.
    private record Command, op : String, key : String, value : String?, start : String, finish : String?, limit : Int32

    getter port : Int32
    getter host : String

    @server : TCPServer?
    @running : Bool
    @ready : Bool

    def initialize(@db : DB, @host : String = "127.0.0.1", @port : Int32 = 7654)
      @server = nil
      @running = true
      @ready = false
    end

    def ready? : Bool
      @ready
    end

    # Accepts connections until a shutdown command arrives.
    def run : Nil
      server = TCPServer.new(@host, @port)
      @server = server
      @port = server.local_address.port
      @ready = true
      puts "Cinderstore #{VERSION}: listening on #{@host}:#{@port}"
      while @running
        begin
          client = server.accept
          spawn handle_client(client)
        rescue ex : IO::Error
          break unless @running
        end
      end
      server.close rescue nil
      @ready = false
    end

    # Stops the accept loop and closes the listening socket.
    def stop : Nil
      @running = false
      @server.try(&.close)
    end

    private def handle_client(client : TCPSocket) : Nil
      shutdown = false
      begin
        while line = client.gets
          line = line.strip
          next if line.empty?
          begin
            command = parse_command(line)
            shutdown = true if command.op == "SHUTDOWN"
            if command.op == "QUERY" || command.op == "QUERYRANGE"
              stream_index_query(client, command)
            else
              response = execute(command)
              client << response << "\n"
              client.flush
            end
          rescue ex : Error
            client << "ERR #{ex.message}\n"
            client.flush
          end
          break if shutdown
        end
      rescue ex : IO::Error
      ensure
        client.close rescue nil
      end
    end

    private def parse_command(line : String) : Command
      parts = line.split(" ", 3)
      op = parts[0]?.try(&.upcase) || ""
      case op
      when "PUT"
        raise ProtocolError.new("missing key") if parts.size < 2
        raise ProtocolError.new("missing value") if parts.size < 3
        Command.new(op, parts[1], parts[2], "", nil, -1)
      when "GET", "DEL", "DELETE"
        raise ProtocolError.new("missing key") if parts.size < 2
        raise ProtocolError.new("too many arguments") if parts.size > 2
        Command.new(op, parts[1], nil, "", nil, -1)
      when "SCAN"
        tokens = line.split(" ")
        start = tokens[1]? || ""
        finish = tokens[2]?
        limit = tokens[3]?.try(&.to_i?) || -1
        Command.new(op, "", nil, start, finish, limit)
      when "QUERY"
        raise ProtocolError.new("missing index") if parts.size < 2
        raise ProtocolError.new("missing index key") if parts.size < 3
        Command.new(op, parts[1], parts[2], "", nil, -1)
      when "QUERYRANGE"
        tokens = line.split(" ")
        raise ProtocolError.new("missing index") if tokens.size < 2
        Command.new(op, tokens[1], nil, tokens[2]? || "", tokens[3]?, -1)
      when "STATS", "PING", "FLUSH", "COMPACT", "SHUTDOWN"
        Command.new(op, "", nil, "", nil, -1)
      else
        raise ProtocolError.new("unknown command: #{op}")
      end
    end

    private def execute(command : Command) : String
      case command.op
      when "PUT"
        @db.put(command.key, command.value.not_nil!)
        "OK"
      when "GET"
        if value = @db.get(command.key)
          "VALUE #{value}"
        else
          "NOT_FOUND"
        end
      when "DEL", "DELETE"
        @db.delete(command.key)
        "OK"
      when "SCAN"
        rows = @db.scan(command.start, command.finish, command.limit)
        if rows.empty?
          "END"
        else
          String.build do |s|
            rows.each do |key, value|
              s << "ROW #{key} #{value}\n"
            end
            s << "END"
          end
        end
      when "STATS"
        "STATS #{@db.stats.to_json}"
      when "PING"
        "PONG"
      when "FLUSH"
        @db.flush
        "OK"
      when "COMPACT"
        @db.compact
        "OK"
      when "SHUTDOWN"
        stop
        "BYE"
      else
        raise ProtocolError.new("unknown command")
      end
    end

    # Streams a query result as one ROW line per primary key, then END.
    #
    # The server never materializes the result. Each row is flushed as the
    # iterator produces it, so a large result keeps a small memory footprint.
    private def stream_index_query(client : TCPSocket, command : Command) : Nil
      iter = if command.op == "QUERY"
               @db.query_iter(command.key, command.value.not_nil!)
             else
               @db.query_range_iter(command.key, command.start, command.finish)
             end
      begin
        while key = iter.next?
          client << "ROW #{key}\n"
          client.flush
        end
        client << "END\n"
      ensure
        iter.close
      end
    end
  end
end
