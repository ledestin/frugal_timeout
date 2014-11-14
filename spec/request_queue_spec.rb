require 'spec_helper'
require './lib/frugal_timeout/request_queue'

describe FrugalTimeout::RequestQueue do
  before :each do
    @ar = []
    @requests = FrugalTimeout::RequestQueue.new
    @requests.onNewNearestRequest { |request|
      @ar << request
    }
  end

  context 'after queueing' do
    context 'invokes onNewNearestRequest callback' do
      it 'just once' do
	@requests.queue(10, FrugalTimeout::Error)
	@ar.size.should == 1
      end

      it 'when next request is nearer than prev' do
	@requests.queue(10, FrugalTimeout::Error)
	@requests.queue(0, FrugalTimeout::Error)
	@ar.size.should == 2
      end
    end

    it "doesn't invoke onNewNearestRequest if request isn't nearest" do
      @requests.queue(10, FrugalTimeout::Error)
      @requests.queue(20, FrugalTimeout::Error)
      @ar.size.should == 1
    end
  end

  context 'after enforceExpired' do
    it 'invokes onEnforce on enforceExpired' do
      called = false
      @requests.onEnforce { called = true }
      @requests.queue(0, FrugalTimeout::Error)
      expect { @requests.enforceExpired }.to raise_error
      called.should == true
    end

    it 'defuses all requests for the thread' do
      req = @requests.queue(10, FrugalTimeout::Error)
      @requests.queue(0, FrugalTimeout::Error)
      thread = nil
      expect {
	(thread = Thread.new { @requests.enforceExpired }).join
      }.to raise_error FrugalTimeout::Error
      thread.join
      req.defused?.should == true
    end

    context 'onNewNearestRequest' do
      it 'invokes onNewNearestRequest' do
	@requests.queue(0, FrugalTimeout::Error)
	expect { @requests.enforceExpired }.to raise_error
	@ar.size.should == 1
      end

      it "doesn't invoke onNewNearestRequest on a defused request" do
	@requests.queue(0, FrugalTimeout::Error).defuse!
	expect { @requests.enforceExpired }.not_to raise_error
	@requests.size.should == 0
	@ar.size == 1
      end

      it "doesn't invoke onNewNearestRequest if no requests expired yet" do
	@requests.queue(10, FrugalTimeout::Error)
	expect { @requests.enforceExpired }.not_to raise_error
	# 1 has been put there by #queue.
	@ar.size.should == 1
      end
    end

    it 'no expired requests are left in the queue' do
      @requests.queue(0, FrugalTimeout::Error)
      @requests.size.should == 1
      expect {
	Thread.new { @requests.enforceExpired }.join
      }.to raise_error
      @requests.size.should == 0
    end

    it 'a non-expired request is left in the queue' do
      @requests.queue(10, FrugalTimeout::Error)
      expect { @requests.enforceExpired }.not_to raise_error
      @requests.size.should == 1
    end
  end
end
