# Copyright (C) 2013, 2014 by Dmitry Maksyoma <ledestin@gmail.com>

module FrugalTimeout
  # Stores values for keys, such as:
  # 1. `set key, val' will store val.
  # 2. `set key, val2' will store [val, val2].
  # 3. `delete key, val2' will lead to storing just val again.
  # I.e. array is used only when it's absolutely necessary.
  #
  # While it's harder to write code because of this, we do save memory by not
  # instantiating all those arrays.
  class Storage #:nodoc:
    def initialize
      @storage = {}
    end

    def delete key, val=nil
      return unless stored = @storage[key]

      if val.nil? || stored == val
	@storage.delete key
	return
      end

      stored.delete val
      @storage[key] = stored.first if stored.size == 1
    end

    def get key
      @storage[key]
    end
    alias :[] :get

    def set key, val
      unless stored = @storage[key]
	@storage[key] = val
	return
      end

      if stored.is_a? Array
	stored << val
      else
	@storage[key] = [stored, val]
      end
    end
  end
end
