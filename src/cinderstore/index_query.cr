module Cinderstore
  # Streams the primary keys of one secondary index query.
  #
  # The iterator reads from a snapshot, so it stays consistent while the
  # database keeps writing. Each `next?` returns the primary key of the
  # next live index association, in index key order.
  #
  # A database-level iterator owns the snapshot it reads. Close it when you
  # are done; that releases the snapshot. A snapshot-level iterator shares
  # the snapshot you created, so closing it never releases that snapshot.
  class IndexIter
    @own_snapshot : Bool

    def initialize(@snapshot : Snapshot, @inner : SnapshotIter, @prefix : String,
                   @finish_key : String?, @own_snapshot : Bool = false)
    end

    # Returns the next primary key, or nil at the end of the query.
    def next? : String?
      finish = @finish_key
      while entry = @inner.next?
        break unless entry.key.starts_with?(@prefix)
        index_key = Index.index_key_of(entry.key)
        break if finish && index_key >= finish
        return Index.primary_key_of(entry.key) if entry.alive
      end
      nil
    end

    # Yields every primary key in order.
    def each(&block : String ->) : Nil
      while key = next?
        yield key
      end
    end

    # Returns every primary key in order.
    def to_a : Array(String)
      keys = [] of String
      each { |key| keys << key }
      keys
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
