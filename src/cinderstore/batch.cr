module Cinderstore
  # A group of key/value changes written as one atomic operation.
  #
  # A batch holds puts and deletes. `DB#write` applies the whole batch or
  # none of it. The batch becomes a single record in the write ahead log,
  # so a crash in the middle of the batch drops the entire batch.
  class Batch
    @ops = [] of Tuple(String, String, Bool)

    # Queues a live value for `key`.
    def put(key : String, value : String) : Nil
      @ops << {key, value, true}
    end

    # Queues a tombstone for `key`.
    def delete(key : String) : Nil
      @ops << {key, "", false}
    end

    # Returns the number of queued operations.
    def size : Int32
      @ops.size
    end

    # Returns true when the batch holds no operations.
    def empty? : Bool
      @ops.empty?
    end

    # Yields each queued operation as key, value, and liveness, in the
    # order the caller queued it. Deletes yield an empty value.
    def each(&block : String, String, Bool ->) : Nil
      @ops.each do |key, value, alive|
        yield key, value, alive
      end
    end
  end
end
