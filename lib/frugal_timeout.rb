# Copyright (C) 2013 by Dmitry Maksyoma <ledestin@gmail.com>

require 'hitimes'
require 'monitor'
require 'thread'
require 'timeout'

#--
# {{{1 Rdoc
#++
# Timeout.timeout() replacement using only 2 threads
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

    def defuse!
      @@mutex.synchronize { @defused = true }
    end

    def defused?
      @@mutex.synchronize { @defused }
    end

    def enforceTimeout
      @@mutex.synchronize {
	@thread.raise @klass, 'execution expired' unless @defused
      }
    end
  end

  # {{{1 RequestQueue
  class RequestQueue # :nodoc:
    def initialize requests, sleeper
      @requests, @sleeper = requests, sleeper
    end

    def queue sec, klass
      @requests.synchronize {
	@requests << (request = Request.new(Thread.current,
	  MonotonicTime.now + sec, klass))
	@sleeper.notifyAfter sec if @requests.first == request
	request
      }
    end

    def purgeExpired
      now = MonotonicTime.now

      # Enforce all expired timeouts.
      @requests.reject! { |r|
	break if r.at > now

	r.enforceTimeout
	true
      }

      # Activate the nearest non-expired timeout.
      @requests.synchronize {
	@sleeper.notifyAfter @requests.first.at - now if @requests.first
      }
    end
  end

  # {{{1 SleeperNotifier
  class SleeperNotifier # :nodoc:
    include MonitorMixin

    def initialize notifyQueue
      super()
      @notifyQueue = notifyQueue
      @latestDelay = nil

      @thread = Thread.new {
	loop {
	  unless sleepFor = latestDelay
	    sleep
	  else
	    sleptFor = MonotonicTime.measure { sleep(sleepFor) }
	  end
	  synchronize {
	    @notifyQueue.push :expired if sleepFor && sleptFor >= sleepFor
	  }
	}
      }
      ObjectSpace.define_finalizer self, proc { @thread.kill }
    end

    def latestDelay
      synchronize {
	tmp = @latestDelay
	@latestDelay = nil
	tmp
      }
    end
    private :latestDelay

    def notifyAfter sec
      synchronize {
	sleep 0.01 until @thread.status == 'sleep'
	sec = 0 if sec < 0
	@latestDelay = sec
	@thread.wakeup
      }
    end
    private :synchronize
  end

  # {{{1 SortedQueue
  class SortedQueue # :nodoc:
    include MonitorMixin

    def initialize storage=[]
      super()
      @array, @unsorted = storage, false
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
  @in = ::Queue.new
  @requestQueue = RequestQueue.new(SortedQueue.new,
    SleeperNotifier.new(@in))

  # {{{2 Timeout request expiration processing thread
  Thread.new {
    loop {
      @in.shift
      @requestQueue.purgeExpired
    }
  }

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
