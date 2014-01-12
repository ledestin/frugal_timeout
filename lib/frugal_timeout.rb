# Copyright (C) 2013, 2014 by Dmitry Maksyoma <ledestin@gmail.com>

require 'monitor'
require 'thread'
require 'timeout'
require 'frugal_timeout/support'

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
  class Error < Timeout::Error #:nodoc:
  end

  # {{{1 Request
  # Timeout request, holding expiry time, what exception to raise and in which
  # thread. It is active by default, but can be defused. If it's defused, then
  # timeout won't be enforced when #enforce is called.
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

    # Timeout won't be enforced if you defuse the request.
    def defuse!
      @@mutex.synchronize { @defused = true }
    end

    def defused?
      @@mutex.synchronize { @defused }
    end

    # Enforce this timeout request, unless it's been defused.
    # Return true if was enforced, false otherwise.
    def enforce
      @@mutex.synchronize {
	return false if @defused

	@thread.raise @klass, 'execution expired'
	@defused = true
	true
      }
    end
  end

  # {{{1 RequestQueue
  # Contains sorted requests to be processed. Calls @onNewNearestRequest when
  # another request becomes the first in line. Calls @onEnforce when expired
  # requests are removed and enforced.
  #
  # #queue adds requests.
  # #enforceExpired removes and enforces requests.
  class RequestQueue #:nodoc:
    include Hookable
    include MonitorMixin

    def initialize
      super
      def_hook_synced :onEnforce, :onNewNearestRequest
      @requests, @threadIdx = SortedQueue.new, Storage.new

      @requests.onAdd { |r| @threadIdx.set r.thread, r }
      @requests.onRemove { |r| @threadIdx.delete r.thread, r }
    end

    def enforceExpired
      synchronize {
	purgeAndEnforceExpired && sendNearestActive
      }
    end

    def size
      synchronize { @requests.size }
    end

    def queue sec, klass
      request = Request.new(Thread.current, MonotonicTime.now + sec, klass)
      synchronize {
	@requests.push(request) {
	  @onNewNearestRequest.call request
	}
      }
      request
    end

    private

    # Defuses requests belonging to the passed thread.
    def defuseForThread! thread
      return unless request = @threadIdx[thread]

      if request.respond_to? :each
	request.each { |r| r.defuse! }
      else
	request.defuse!
      end
    end

    def purgeAndEnforceExpired
      @onEnforce.call
      now = MonotonicTime.now
      @requests.reject_until_mismatch! { |r|
	if r.at <= now
	  r.enforce && defuseForThread!(r.thread)
	  true
	end
      }
    end

    def sendNearestActive
      @requests.reject_until_mismatch! { |r| r.defused? }
      @onNewNearestRequest.call @requests.first unless @requests.empty?
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
    include Hookable
    include MonitorMixin

    def initialize
      super()
      def_hook_synced :onExpiry
      @condVar, @expireAt = new_cond, nil

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

  # {{{1 Main code
  @requestQueue = RequestQueue.new
  sleeper = SleeperNotifier.new
  @requestQueue.onNewNearestRequest { |request|
    sleeper.expireAt request.at
  }
  sleeper.onExpiry { @requestQueue.enforceExpired }

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
