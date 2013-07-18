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
  # {{{2 Error
  class Error < Timeout::Error; end

  # {{{2 Request
  class Request
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

  # {{{2 Main code
  @in = Queue.new

  # {{{3 Timeout request and expiration processing thread
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
	  setupSleeper requests.first.at - now
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

      setupSleeper request.at - now
      nearestTimeout = request.at
    }
  }

  # {{{3 Closest expiration notifier thread
  @sleeperDelays, @sleeperMutex = Queue.new, Mutex.new
  @sleeper = Thread.new {
    loop {
      sleepFor = nil
      @sleeperMutex.synchronize {
	sleepFor = @sleeperDelays.shift until @sleeperDelays.empty?
      }
      start = Time.now
      sleepFor ? sleep(sleepFor) : sleep
      @sleeperMutex.synchronize {
	@in.push :expired if sleepFor && Time.now - start >= sleepFor
      }
    }
  }

  # {{{3 Methods

  # Ensure that calling timeout() will use FrugalTimeout.timeout()
  def self.dropin!
    Object.class_eval \
      'def timeout t, klass=nil, &b
	 FrugalTimeout.timeout t, klass, &b
       end'
  end

  def self.setupSleeper sleepFor # :nodoc:
    @sleeperMutex.synchronize {
      sleep 0.1 until @sleeper.status == 'sleep'
      @sleeperDelays.push sleepFor
      @sleeper.wakeup
    }
  end
  private :setupSleeper

  # Same as Timeout.timeout()
  def self.timeout t, klass=nil
    @in.push request = Request.new(Thread.current, Time.now + t, klass)
    begin
      yield t
    ensure
      request.done! unless $!.is_a? FrugalTimeout::Error
    end
  end
  # }}}2
end
