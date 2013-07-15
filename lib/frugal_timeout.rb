# Copyright (C) 2013 by Dmitry Maksyoma <ledestin@gmail.com>

require 'thread'
require 'timeout'

module FrugalTimeout
  # {{{1 Error
  class Error < Timeout::Error; end

  # {{{1 Request
  class Request
    include Comparable
    @@mutex = Mutex.new

    attr_reader :at, :thread

    def initialize thread, at
      @thread, @at = thread, at
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
      @thread.raise Error, 'execution expired' unless done?
    end
  end

  # {{{1 Main code
  @in = Queue.new

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

  # {{{2 Closest expiration notifier thread
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

  # {{{2 Methods
  # Replace Object.timeout().
  def self.dropin!
    Object.class_eval \
      'def timeout t, klass=nil, &b
	 FrugalTimeout.timeout t, klass, &b
       end'
  end

  def self.setupSleeper sleepFor
    @sleeperMutex.synchronize {
      sleep 0.1 until @sleeper.status == 'sleep'
      @sleeperDelays.push sleepFor
      @sleeper.wakeup
    }
  end

  def self.timeout t, klass=nil
    @in.push request = Request.new(Thread.current, Time.now + t)
    begin
      yield t
    ensure
      request.done! unless $!.is_a? FrugalTimeout::Error
    end
  end
  #}}}1
end
