module Cinderstore
  # Base class for all Cinderstore errors.
  class Error < Exception
  end

  # Raised when on-disk data fails a checksum or layout check.
  class CorruptDataError < Error
  end

  # Raised when an operation targets a closed database.
  class ClosedError < Error
  end

  # Raised when a key fails validation.
  class InvalidKeyError < Error
  end

  # Raised when a value fails validation.
  class InvalidValueError < Error
  end

  # Raised when a command does not follow the wire protocol.
  class ProtocolError < Error
  end
end
