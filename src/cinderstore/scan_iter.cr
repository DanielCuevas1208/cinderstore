module Cinderstore
  # Streams live key/value pairs over a primary key range.
  #
  # The iterator reads from a snapshot, so it stays consistent while the
  # database keeps writing. Each `next?` returns the next live pair in
  # ascending key order. The range is [start, finish).
  #
  # A database-level iterator owns the snapshot it reads. Close it when you
  # are done; that releases the snapshot. A snapshot-level iterator shares
  # the snapshot you created, so closing it never releases that snapshot.
  class ScanIter
    @own_snapshot : Bool

    def initialize(@snapshot : Snapshot, @inner : Store::Iter, @finish_key : String?,
                   @own_snapshot : Bool = false)
    end

    # Returns the next key/value pair, or nil at the end of the range.
    def next? : Tuple(String, String)?
      finish = @finish_key
      while entry = @inner.next?
        break if finish && entry.key >= finish
        return {entry.key, entry.value}
      end
      nil
    end

    # Yields every key/value pair in key order.
    def each(&block : String, String ->) : Nil
      while pair = next?
        yield pair[0], pair[1]
      end
    end

    # Returns every key/value pair in key order.
    def to_a : Array(Tuple(String, String))
      pairs = [] of Tuple(String, String)
      each { |key, value| pairs << {key, value} }
      pairs
    end

    # Marks this iterator as the owner of its snapshot. Closing the
    # iterator then releases the snapshot. The database uses this for the
    # snapshot it creates internally.
    def take_ownership : Nil
      @own_snapshot = true
    end

    # Releases the snapshot this iterator owns, if any.
    def close : Nil
      @inner.close
      @snapshot.release if @own_snapshot
    end
  end
end
