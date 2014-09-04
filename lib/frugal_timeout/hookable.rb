# Copyright (C) 2013, 2014 by Dmitry Maksyoma <ledestin@gmail.com>

module FrugalTimeout
  module Hookable #:nodoc:
    DO_NOTHING = proc {}

    def def_hook *names
      names.each { |name|
	eval <<-EOF
	  def #{name} &b
	    @#{name} = b || DO_NOTHING
	  end
	  #{name}
	EOF
      }
    end

    def def_hook_synced *names
      names.each { |name|
	eval <<-EOF
	  def #{name} &b
	    synchronize { @#{name} = b || DO_NOTHING }
	  end
	  #{name}
	EOF
      }
    end
  end
end
