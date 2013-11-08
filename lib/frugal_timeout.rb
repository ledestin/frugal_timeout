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
  # {{{1 SortedQueue
  class SortedQueue
    extend Forwardable
    def_delegators :@array, :size

    def initialize storage=[]
      @array, @unsorted = storage, false
    end

    def first
      @array.first
    end

    def last
      sort!
      @array.last
    end

    def push *args
      args.each { |arg|
	case @array.first <=> arg
	when -1, 0, nil
	  @array.push arg
	when 1
	  @array.unshift arg
	end
      }
      @unsorted = true
    end
    alias :<< :push

    def reject! &b
      sort!
      @array.reject! &b
    end

    private
    def sort!
      return unless @unsorted

      @array.sort!
      @unsorted = false
    end
  end

  # {{{1 Request
  class Request # :nodoc:
    include Comparable
    @@mutex = Mutex.new

    attr_reader :at, :thread

    def initialize thread, at, klass
      @thread, @at, @klass = thread, at, klass
      @done = false
    end

    def <=>(other)
      @at <=> other.at
    end

    def done!
      @@mutex.synchronize { @done = true }
    end

    def done?
      @@mutex.synchronize { @done }
    end

    def enforceTimeout
      @@mutex.synchronize {
	@thread.raise @klass || Error, 'execution expired' unless @done
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
	@latestDelay = sec
	@thread.wakeup
      }
    end
    private :synchronize
  end

  # {{{1 Main code
  @in = ::Queue.new
  @sleeper = SleeperNotifier.new @in

  # {{{2 Timeout request and expiration processing thread
  Thread.new {
    requests = SortedQueue.new
    loop {
      request = @in.shift
      now = MonotonicTime.now

      if request == :expired
	# Enforce all expired timeouts.
	requests.reject! { |r|
	  break if r.at > now

	  r.enforceTimeout
	  true
	}

	# Activate the nearest non-expired timeout.
	@sleeper.notifyAfter requests.first.at - now if requests.first
	next
      end

      # New timeout request.
      # Already expired, enforce right away.
      if request.at <= now
	request.enforceTimeout
	next
      end

      # Queue new timeout for later enforcing. Activate if it's nearest to
      # enforce.
      requests << request
      @sleeper.notifyAfter request.at - now if requests.first == request
    }
  }


  # {{{2 Methods

  # Ensure that calling timeout() will use FrugalTimeout.timeout()
  def self.dropin!
    Object.class_eval \
      'def timeout t, klass=nil, &b
	 FrugalTimeout.timeout t, klass, &b
       end'
  end

  # Same as Timeout.timeout()
  def self.timeout sec, klass=nil
    return yield sec if sec == nil || sec <= 0

    @in.push request = Request.new(Thread.current, MonotonicTime.now + sec,
      klass)
    begin
      yield sec
    ensure
      request.done! unless $!.is_a? FrugalTimeout::Error
    end
  end
  # }}}1
end
