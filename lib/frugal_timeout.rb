# Copyright (C) 2013 by Dmitry Maksyoma <ledestin@gmail.com>

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

  # {{{1 Request
  class Request # :nodoc:
    include Comparable
    @@mutex = Mutex.new

    attr_reader :at, :thread

    def initialize thread, at, klass
      @thread, @at, @klass = thread, at, klass
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
      @thread.raise @klass || Error, 'execution expired' unless done?
    end
  end

  # {{{1 SleeperNotifier
  class SleeperNotifier # :nodoc:
    def initialize notifyQueue
      @notifyQueue = notifyQueue
      @delays, @mutex = [], Mutex.new

      @thread = Thread.new {
	loop {
	  sleepFor, start = synchronize { latestDelay }, Time.now
	  sleepFor ? sleep(sleepFor) : sleep
	  synchronize {
	    @notifyQueue.push :expired \
	      if sleepFor && Time.now - start >= sleepFor
	  }
	}
      }
      ObjectSpace.define_finalizer self, proc { @thread.kill }
    end

    def latestDelay
      delay = @delays.last
      @delays.clear
      delay
    end
    private :latestDelay

    def notifyAfter sec
      synchronize {
	sleep 0.01 until @thread.status == 'sleep'
	@delays.push sec
	@thread.wakeup
      }
    end

    def synchronize &b
      @mutex.synchronize &b
    end
    private :synchronize
  end

  # {{{1 Main code
  @in = Queue.new
  @sleeper = SleeperNotifier.new @in

  # {{{2 Timeout request and expiration processing thread
  Thread.new {
    nearestTimeout, requests = nil, []
    loop {
      request = @in.shift
      now = Time.now

      if request == :expired
	# Enforce all expired timeouts.
	requests.sort!
	requests.each_with_index { |r, i|
	  break if r.at > now

	  r.enforceTimeout
	  requests[i] = nil
	}
	requests.compact!

	# Activate the nearest non-expired timeout.
	nearestTimeout = unless requests.first
	  nil
	else
	  @sleeper.notifyAfter requests.first.at - now
	  requests.first.at
	end

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
      next if nearestTimeout && request.at > nearestTimeout

      @sleeper.notifyAfter request.at - now
      nearestTimeout = request.at
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

    @in.push request = Request.new(Thread.current, Time.now + sec, klass)
    begin
      yield sec
    ensure
      request.done! unless $!.is_a? FrugalTimeout::Error
    end
  end
  # }}}1
end
