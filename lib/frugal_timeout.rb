# Copyright (C) 2013, 2014 by Dmitry Maksyoma <ledestin@gmail.com>

require 'hitimes'
require 'monitor'
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
  DO_NOTHING = proc {}

  # {{{1 Error
  class Error < Timeout::Error #:nodoc:
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

  # {{{1 Request
  class Request #:nodoc:
    include Comparable
    @@mutex = Mutex.new

    attr_reader :at, :klass, :thread

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

    def enforceTimeout
      @@mutex.synchronize {
	return if @defused

	@thread.raise @klass, 'execution expired'
	true
      }
    end
  end

  # {{{1 RequestQueue
  class RequestQueue #:nodoc:
    extend Forwardable

    def_delegators :@requests, :empty?, :first, :<<

    def initialize
      @onEnforce, @onNewNearestRequest, @requests, @threadReq =
	DO_NOTHING, DO_NOTHING, SortedQueue.new, {}
    end

    def defuse_thread! thread
      @requests.synchronize {
	stored = @threadReq.delete thread
	stored.each { |r| r.defuse! } if stored.is_a? Array
      }
    end
    private :defuse_thread!

    def onEnforce &b
      @onEnforce = b || DO_NOTHING
    end

    def onNewNearestRequest &b
      @onNewNearestRequest = b || DO_NOTHING
    end

    # Purge and enforce expired timeouts. Only enforce once for each thread,
    # even if multiple timeouts for that thread expire at once.
    def purgeExpired
      @requests.synchronize {
	@onEnforce.call

	now = MonotonicTime.now
	@requests.reject_and_get! { |r| r.at <= now }.each { |r|
	  defuse_thread!(r.thread) if r.enforceTimeout
	}

	# It's necessary to call onNewNearestRequest inside synchronize as other
	# threads may #queue requests.
	@requests.reject_and_get! { |r| r.defused? }
	@onNewNearestRequest.call @requests.first unless @requests.empty?
      }
    end

    def storeInIndex request
      unless stored = @threadReq[request.thread]
	@threadReq[request.thread] = request
	return
      end

      if stored.is_a? Array
	stored << request
      else
	@threadReq[request.thread] = [stored, request]
      end
    end
    private :storeInIndex

    def queue sec, klass
      @requests.synchronize {
	@requests << (request = Request.new(Thread.current,
	  MonotonicTime.now + sec, klass))
	storeInIndex request
	@onNewNearestRequest.call(request) if @requests.first == request
	request
      }
    end
  end

  # {{{1 SleeperNotifier
  # Executes callback when a request expires.
  # 1. Set callback to execute with #onExpiry=.
  # 2. Set expiry time with #expireAt.
  # 3. After the expiry time comes, execute the callback.
  #
  # It's possible to set a new expiry time before the time set previously
  # expires. In this case, processing of the old request stops and the new
  # request processing starts.
  class SleeperNotifier #:nodoc:
    include MonitorMixin

    def initialize
      super()
      @condVar, @expireAt, @onExpiry = new_cond, nil, DO_NOTHING

      @thread = Thread.new {
	loop {
	  synchronize { @onExpiry }.call if synchronize {
	    # Sleep forever until a request comes in.
	    unless @expireAt
	      wait
	      next
	    end

	    timeLeft = calcTimeLeft
	    disposeOfRequest
	    elapsedTime = MonotonicTime.measure { wait timeLeft }

	    elapsedTime >= timeLeft
	  }
	}
      }
      ObjectSpace.define_finalizer self, proc { @thread.kill }
    end

    def onExpiry &b
      synchronize { @onExpiry = b || DO_NOTHING }
    end

    def expireAt time
      synchronize {
	@expireAt = time
	signalThread
      }
    end

    private

    def calcTimeLeft
      synchronize {
	delay = @expireAt - MonotonicTime.now
	delay < 0 ? 0 : delay
      }
    end

    def disposeOfRequest
      @expireAt = nil
    end

    def signalThread
      @condVar.signal
    end

    def wait sec=nil
      @condVar.wait sec
    end
  end

  # {{{1 SortedQueue
  class SortedQueue #:nodoc:
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
    sleeper.expireAt request.at
  }
  sleeper.onExpiry { @requestQueue.purgeExpired }

  # {{{2 Methods

  # Ensure that calling timeout() will use FrugalTimeout.timeout()
  def self.dropin!
    Object.class_eval \
      'def timeout t, klass=nil, &b
	 FrugalTimeout.timeout t, klass, &b
       end'
  end

  def self.on_enforce &b #:nodoc:
    @requestQueue.onEnforce &b
  end

  def self.on_ensure &b #:nodoc:
    @onEnsure = b
  end

  # Same as Timeout.timeout()
  def self.timeout sec, klass=nil
    return yield sec if sec.nil? || sec <= 0

    innerException = klass || Class.new(Timeout::ExitException)
    request = @requestQueue.queue(sec, innerException)
    begin
      yield sec
    rescue innerException => e
      raise if klass

      raise Error, e.message, e.backtrace
    ensure
      @onEnsure.call if @onEnsure
      request.defuse!
    end
  end
  # }}}1
end
