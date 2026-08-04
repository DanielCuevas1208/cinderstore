require "sync/condition_variable"

module Cinderstore
  # Coalesces durability syncs from concurrent writers.
  #
  # A writer appends its record to a write ahead log, then registers with
  # the group. One committer fiber waits for pending writers, syncs the log
  # once, and releases them all. A burst of writes therefore pays for one
  # fsync instead of one per write.
  class CommitGroup
    @mutex = Mutex.new
    @cv : Sync::ConditionVariable
    @pending : Array(Tuple(Channel(Nil), Wal::Writer)) = [] of Tuple(Channel(Nil), Wal::Writer)
    @shutdown : Bool = false
    @commits : Int64 = 0_i64
    @done : Channel(Nil) = Channel(Nil).new
    @committer : Fiber

    def initialize
      @cv = Sync::ConditionVariable.new(@mutex)
      @committer = spawn { run }
    end

    # Returns how many times the group has synced a log.
    getter commits : Int64

    # Registers the current fiber for a durability sync on `wal`, then
    # blocks until the group makes the log durable.
    def commit(wal : Wal::Writer) : Nil
      gate = Channel(Nil).new
      @mutex.synchronize do
        if @shutdown
          # The committer is gone. Sync directly so the caller still gets
          # its durability guarantee.
          wal.sync
          return
        end
        @pending << {gate, wal}
        @cv.signal
      end
      gate.receive
    end

    # Drains the pending writers, then stops the committer.
    def shutdown : Nil
      @mutex.synchronize do
        @shutdown = true
        @cv.broadcast
      end
      @done.receive
    end

    private def run : Nil
      loop do
        break unless wait_first
        # A single yield lets every ready writer register before we drain.
        # One sync then covers the whole burst.
        Fiber.yield
        group = @mutex.synchronize { drain_all }
        unless group.empty?
          group.map(&.[1]).uniq.each(&.sync)
          @mutex.synchronize { @commits += 1 }
          group.each { |gate, _wal| gate.send(nil) }
        end
      end
      @done.send(nil)
    end

    # Blocks until a writer waits or the group shuts down. Returns true
    # when a writer is pending.
    private def wait_first : Bool
      @mutex.synchronize do
        while @pending.empty? && !@shutdown
          @cv.wait
        end
        !@pending.empty?
      end
    end

    # Removes every pending writer from the list.
    private def drain_all : Array(Tuple(Channel(Nil), Wal::Writer))
      group = @pending
      @pending = [] of Tuple(Channel(Nil), Wal::Writer)
      group
    end
  end
end
