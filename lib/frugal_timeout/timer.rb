# Copyright (C) 2013, 2014 by Dmitry Maksyoma <ledestin@gmail.com>

require 'monotonic_time'
require 'frugal_timeout/hookable'

module FrugalTimeout
  # Executes callback at a time, specified by #notifyAt.
  #
  # How to use:
  # 1. Setup callback using #onNotify (e.g. onNotify { puts 'notified' }).
  # 2. Set notification time with #notifyAt.
  # 3. After the notification time comes, execute the callback.
  #
  # It's possible to set a new notification time before the time set previously
  # expires. However, if the old request has already expired, the callback will
  # still be called.
  class Timer #:nodoc:
    include Hookable
    include MonitorMixin

    def initialize
      super()
      def_hook_synced :onNotify
      @condVar, @notifyAt = new_cond, nil

      @thread = Thread.new { processRequests }
      ObjectSpace.define_finalizer self, proc { @thread.kill }
    end

    def notifyAt time
      synchronize {
	@notifyAt = time
	stopWaiting
      }
    end

    private

    def disposeOfRequest
      @notifyAt = nil
    end

    def processRequests
      loop {
	synchronize { @onNotify }.call if synchronize {
	  waitForValidRequest

	  timeLeft = timeLeftUntilNotify
	  # Prevent processing of the same request again.
	  disposeOfRequest
	  elapsedTime = MonotonicTime.measure { wait timeLeft }

	  elapsedTime >= timeLeft
	}
      }
    end

    def stopWaiting
      @condVar.signal
    end

    def timeLeftUntilNotify
      delay = @notifyAt - MonotonicTime.now
      delay < 0 ? 0 : delay
    end

    def wait sec=nil
      @condVar.wait sec
    end

    def waitForValidRequest
      wait until @notifyAt
    end
  end
end
