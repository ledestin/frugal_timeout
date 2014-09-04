# Copyright (C) 2013, 2014 by Dmitry Maksyoma <ledestin@gmail.com>

module FrugalTimeout
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
end
