# Copyright (C) 2013, 2014 by Dmitry Maksyoma <ledestin@gmail.com>

require 'timeout'
require 'frugal_timeout/request'
require 'frugal_timeout/request_queue'
require 'frugal_timeout/timer'

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
  # Each timeout() call produces a request that contains expiry time. All new
  # requests are put into a queue, and when the nearest request expires, all
  # expired requests raise exceptions and are removed from the queue.
  #
  # Timer is setup here to trigger exception raising (for expired requests) when
  # the nearest request expires. And queue is setup to let Timer know of the
  # nearest expiry time.
  @requestQueue, timer = RequestQueue.new, Timer.new
  @requestQueue.onNewNearestRequest { |request|
    timer.notifyAt request.at
  }
  timer.onNotify { @requestQueue.enforceExpired }

  # Ensure that calling ::timeout() will use FrugalTimeout.timeout()
  def self.dropin!
    Object.class_eval \
      'def timeout sec, klass=nil, &b
         FrugalTimeout.timeout sec, klass, &b
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

    # Exception to raise on timeout expiry *inside* yield. A unique class is
    # needed to prevent #timeout() calls within yield from rescuing it.
    innerException = klass || Class.new(Timeout::ExitException)
    begin
      request = @requestQueue.queue(sec, innerException)
      # 'defuse!' is here only for the case when exception comes from the yield
      # block. Otherwise, when timeout exception is raised, the request is
      # defused automatically.
      #
      # Now, if in ensure, timeout exception comes, the request has already been
      # defused automatically, so even if ensure is interrupted, there's no
      # problem.
      begin
	yield sec
      ensure
	request.defuse!
      end
    rescue innerException => e
      # Respect user's choice of exception.
      raise if klass

      raise Error, e.message, e.backtrace
    ensure
      @onEnsure.call if @onEnsure
    end
  end
end
