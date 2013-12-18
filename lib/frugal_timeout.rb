# Copyright (C) 2013 by Dmitry Maksyoma <ledestin@gmail.com>

require 'hitimes'
require 'monitor'
require 'null_object'
require 'thread'
require 'timeout'

#--
# {{{1 Rdoc
#++
# Timeout.timeout() replacement using only 1 thread
# = Example
#
#   require 'frugal_timeout'
#
#   begin
#     FrugalTimeout.timeout(0.1) { sleep }
#   rescue Timeout::Error
#     puts 'it works!'
#   end
#
#   # Ensure that calling timeout() will use FrugalTimeout.timeout().
#   FrugalTimeout.dropin!
#
#   # Rescue frugal-specific exception if needed.
#   begin
#     timeout(0.1) { sleep }
#   rescue FrugalTimeout::Error
#     puts 'yay!'
#   end
#--
# }}}1
module FrugalTimeout
  # {{{1 Error
  class Error < Timeout::Error; end # :nodoc:

  # {{{1 MonotonicTime
  class MonotonicTime # :nodoc:
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
  # {{{1 Request
  class Request # :nodoc:
    include Comparable
    @@mutex = Mutex.new

    attr_reader :at, :thread

    def initialize thread, at, klass
      @thread, @at, @klass = thread, at, klass
      @defused = false
    end

    def <=>(other)
      @at <=> other.at
    end

    # Timeout won't be enforced if you defuse a request.
    def defuse!
      @@mutex.synchronize { @defused = true }
    end

    def defused?
      @@mutex.synchronize { @defused }
    end

    def enforceTimeout filter=NullObject.new {}
      @@mutex.synchronize {
	return if @defused || filter.has_key?(@thread)

	filter[@thread] = true
	@thread.raise @klass, 'execution expired'
      }
    end
  end

  # {{{1 RequestQueue
  class RequestQueue # :nodoc:
    extend Forwardable

    def_delegators :@requests, :empty?, :first, :<<

    def initialize
      @onNewNearestRequest, @requests = proc {}, SortedQueue.new
    end

    def onNewNearestRequest &b
      @onNewNearestRequest = b
    end

    # Purge and enforce expired timeouts. Only enforce once for each thread,
    # even if multiple timeouts for that thread expire at once.
    def purgeExpired
      filter, now = {}, MonotonicTime.now
      @requests.reject_and_get! { |r| r.at <= now }.each { |r|
	r.enforceTimeout filter
      }

      @requests.synchronize {
	@onNewNearestRequest.call(@requests.first) unless @requests.empty?
      }
    end

    def queue sec, klass
      @requests.synchronize {
	@requests << (request = Request.new(Thread.current,
	  MonotonicTime.now + sec, klass))
	@onNewNearestRequest.call(request) if @requests.first == request
	request
      }
    end
  end

  # {{{1 SleeperNotifier
  class SleeperNotifier # :nodoc:
    include MonitorMixin

    def initialize
      super()
      @condVar, @onExpiry, @request = new_cond, proc {}, nil

      @thread = Thread.new {
	loop {
	  @onExpiry.call if synchronize {
	    sleepFor = latestDelay
	    sleptFor = MonotonicTime.measure { @condVar.wait sleepFor }

	    if sleepFor && sleptFor >= sleepFor
	      @request = nil
	      true
	    end
	  }
	}
      }
      ObjectSpace.define_finalizer self, proc { @thread.kill }
    end

    def latestDelay
      synchronize {
	return unless @request

	delay = @request.at - MonotonicTime.now
	delay < 0 ? 0 : delay
      }
    end
    private :latestDelay

    def notify
      @condVar.signal
    end
    private :notify

    def onExpiry &b
      @onExpiry = b
    end

    def sleepUntilExpires request
      synchronize {
	@request = request
	notify
      }
    end
  end

  # {{{1 SortedQueue
  class SortedQueue # :nodoc:
    include MonitorMixin

    def initialize storage=[]
      super()
      @array, @unsorted = storage, false
    end

    def empty?
      synchronize { @array.empty? }
    end

    def first
      synchronize { @array.first }
    end

    def last
      synchronize {
	sort!
	@array.last
      }
    end

    def push *args
      synchronize {
	args.each { |arg|
	  case @array.first <=> arg
	  when -1, 0, nil
	    @array.push arg
	  when 1
	    @array.unshift arg
	  end
	}
	@unsorted = true
      }
    end
    alias :<< :push

    def reject! &b
      synchronize {
	sort!
	@array.reject! &b
      }
    end

    def reject_and_get! &b
      res = []
      reject! { |el|
	break unless b.call el

	res << el
      }
      res
    end

    def size
      synchronize { @array.size }
    end

    private
    def sort!
      return unless @unsorted

      @array.sort!
      @unsorted = false
    end
  end

  # {{{1 Main code
  @requestQueue = RequestQueue.new
  sleeper = SleeperNotifier.new
  @requestQueue.onNewNearestRequest { |request|
    sleeper.sleepUntilExpires request
  }
  sleeper.onExpiry { @requestQueue.purgeExpired }

  # {{{2 Methods

  # Ensure that calling timeout() will use FrugalTimeout.timeout()
  def self.dropin!
    Object.class_eval \
      'def timeout t, klass=Error, &b
	 FrugalTimeout.timeout t, klass, &b
       end'
  end

  # Same as Timeout.timeout()
  def self.timeout sec, klass=Error
    return yield sec if sec.nil? || sec <= 0

    request = @requestQueue.queue(sec, klass)
    begin
      yield sec
    ensure
      request.defuse!
    end
  end
  # }}}1
end
