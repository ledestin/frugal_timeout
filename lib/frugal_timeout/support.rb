# Copyright (C) 2013, 2014 by Dmitry Maksyoma <ledestin@gmail.com>

require 'hitimes'

module FrugalTimeout
  # {{{1 Hookable
  module Hookable
    DO_NOTHING = proc {}

    def def_hook *names
      names.each { |name|
	eval <<-EOF
	  def #{name} &b
	    @#{name} = b || DO_NOTHING
	  end
	  #{name}
	EOF
      }
    end

    def def_hook_synced *names
      names.each { |name|
	eval <<-EOF
	  def #{name} &b
	    synchronize { @#{name} = b || DO_NOTHING }
	  end
	  #{name}
	EOF
      }
    end
  end

  # {{{1 MonotonicTime
  class MonotonicTime #:nodoc:
    NANOS_IN_SECOND = 1_000_000_000

    def self.measure
      start = now
      yield
      now - start
    end

    def self.now
      Hitimes::Interval.now.start_instant.to_f/NANOS_IN_SECOND
    end
  end

  # {{{1 SortedQueue
  # Array-like structure, providing automatic sorting of elements. When you're
  # accessing elements via #reject! or #first, the elements you access are
  # sorted. There are some optimizations to ensure that elements aren't sorted
  # each time you call those methods.
  #
  # Provides hooks: on_add, on_remove.
  # To setup, do something like this: `queue.on_add { |el| puts "added #{el}" }'.
  class SortedQueue #:nodoc:
    extend Forwardable
    include Hookable

    # I don't sort underlying array before calling #first because:
    # 1. When a new element is added, it'll be placed correctly at the beginning
    #    if it should be first.
    # 2. If items are removed from the underlying array, it'll be in the sorted
    #    state afterwards. Thus, in this case, #first will behave correctly as
    #    well.
    def_delegators :@array, :empty?, :first, :size

    def initialize storage=[]
      super()
      @array, @unsorted = storage, false
      def_hook :on_add, :on_remove
    end

    def push *args
      raise ArgumentError, "block can't be given for multiple elements" \
	if block_given? && args.size > 1

      args.each { |arg|
	case @array.first <=> arg
	when -1
	  @array.push arg
	  @unsorted = true
	when 0
	  @array.unshift arg
	when 1, nil
	  @array.unshift arg
	  yield arg if block_given?
	end
	@on_add.call arg
      }
    end
    alias :<< :push

    def reject! &b
      sort!
      @array.reject! { |el|
	if b.call el
	  @on_remove.call el
	  true
	end
      }
    end

    def reject_until_mismatch! &b
      curSize = size
      reject! { |el|
	break unless b.call el

	true
      }
      curSize == size ? nil : self
    end

    private
    def sort!
      return unless @unsorted

      @array.sort!
      @unsorted = false
    end
  end

  # {{{1 Storage
  # Stores values for keys, such as:
  # 1. `set key, val' will store val.
  # 2. `set key, val2' will store [val, val2].
  # 3. `delete key, val2' will lead to storing just val again.
  # I.e. array is used only when it's absolutely necessary.
  #
  # While it's harder to write code because of this, we do save memory by not
  # instantiating all those arrays.
  class Storage
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
  # }}}1
end
