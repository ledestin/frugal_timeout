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
    include MonitorMixin

    def initialize
      super
      @onEnforce, @onNewNearestRequest = DO_NOTHING, DO_NOTHING
      @requests, @threadIdx = SortedQueue.new, Storage.new

      @requests.onAdd { |r| @threadIdx.set r.thread, r }
      @requests.onRemove { |r| @threadIdx.delete r.thread, r }
    end

    def defuse_thread! thread
      stored = @threadIdx[thread]
      stored.each { |r| r.defuse! } if stored.is_a? Array
    end
    private :defuse_thread!

    def onEnforce &b
      synchronize { @onEnforce = b || DO_NOTHING }
    end

    def onNewNearestRequest &b
      synchronize { @onNewNearestRequest = b || DO_NOTHING }
    end

    # Purge and enforce expired timeouts.
    def purgeExpired
      synchronize {
	@onEnforce.call

	now = MonotonicTime.now
	@requests.reject_until_mismatch! { |r| r.at <= now }.each { |r|
	  r.enforceTimeout && defuse_thread!(r.thread)
	}

	@requests.reject_until_mismatch! { |r| r.defused? }
	# It's necessary to call onNewNearestRequest inside synchronize as other
	# threads may #queue requests.
	@onNewNearestRequest.call @requests.first unless @requests.empty?
      }
    end

    def queue sec, klass
      synchronize {
	@requests << (request = Request.new(Thread.current,
	  MonotonicTime.now + sec, klass))
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
    extend Forwardable

    def_delegators :@array, :empty?, :first, :size

    def initialize storage=[]
      super()
      @array, @unsorted = storage, false
      @onAdd = @onRemove = DO_NOTHING
    end

    def last
      sort!
      @array.last
    end

    def onAdd &b
      @onAdd = b || DO_NOTHING
    end

    def onRemove &b
      @onRemove = b || DO_NOTHING
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
      args.each { |arg| @onAdd.call arg }
    end
    alias :<< :push

    def reject! &b
      ar = []
      sort!
      @array.reject! { |el|
	ar << el if b.call el
      }
      ar.each { |el| @onRemove.call el }
    end

    def reject_until_mismatch! &b
      res = []
      reject! { |el|
	break unless b.call el

	res << el
      }
      res
    end

    private
    def sort!
      return unless @unsorted

      @array.sort!
      @unsorted = false
    end
  end

  # {{{1 Storage
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
