# Copyright (C) 2013, 2014 by Dmitry Maksyoma <ledestin@gmail.com>

require 'monotonic_time'
require 'frugal_timeout/error'
require 'frugal_timeout/hookable'
require 'frugal_timeout/request'
require 'frugal_timeout/sorted_queue'
require 'frugal_timeout/storage'

module FrugalTimeout
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

      @requests.on_add { |r| @threadIdx.set r.thread, r }
      @requests.on_remove { |r| @threadIdx.delete r.thread, r }
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

    # Defuse requests belonging to the passed thread.
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
end
