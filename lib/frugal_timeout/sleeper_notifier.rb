# Copyright (C) 2013, 2014 by Dmitry Maksyoma <ledestin@gmail.com>

require 'monotonic_time'
require 'frugal_timeout/hookable'

module FrugalTimeout
  # Executes callback when a request expires.
  # 1. Set callback to execute with #onExpiry=.
  # 2. Set expiry time with #expireAt.
  # 3. After the expiry time comes, execute the callback.
  #
  # It's possible to set a new expiry time before the time set previously
  # expires. However, if the old request has already expired, @onExpiry will
  # still be called.
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
	    waitForValidRequest

	    timeLeft = timeLeftUntilExpiry
	    # Prevent processing of the same request again.
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

    def disposeOfRequest
      @expireAt = nil
    end

    def signalThread
      @condVar.signal
    end

    def timeLeftUntilExpiry
      delay = @expireAt - MonotonicTime.now
      delay < 0 ? 0 : delay
    end

    def wait sec=nil
      @condVar.wait sec
    end

    def waitForValidRequest
      wait until @expireAt
    end
  end
end
