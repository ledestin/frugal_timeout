#!/usr/bin/env ruby

require 'rspec'
require 'spec_helper'
require 'frugal_timeout'

FrugalTimeout.dropin!
Thread.abort_on_exception = true
MonotonicTime = FrugalTimeout::MonotonicTime

SMALLEST_TIMEOUT = 0.0000001

# {{{1 Helper methods
def multiple_timeouts growing, cnt
  res, resMutex = [], Mutex.new
  if growing
    1.upto(cnt) { |sec| new_timeout_request_thread sec, res, resMutex } 
  else
    cnt.downto(1) { |sec| new_timeout_request_thread sec, res, resMutex } 
  end
  sleep 1 until res.size == cnt
  res.each_with_index { |t, i| t.round.should == i + 1 }
end

def new_timeout_request sec, res, resMutex
  begin
    start = MonotonicTime.now
    timeout(sec) { sleep }
  rescue FrugalTimeout::Error
    resMutex.synchronize { res << MonotonicTime.now - start }
  end
end

def new_timeout_request_thread sec, res, resMutex
  Thread.new { new_timeout_request sec, res, resMutex }
end

# {{{1 FrugalTimeout
describe FrugalTimeout do
  it 'handles multiple < 1 sec timeouts correctly' do
    LargeDelay, SmallDelay = 0.44, 0.1
    ar, arMutex, started = [], Mutex.new, false
    Thread.new {
      begin
	timeout(LargeDelay) { started = true; sleep }
      rescue FrugalTimeout::Error
	arMutex.synchronize { ar << LargeDelay }
      end
    }
    sleep 0.01 until started
    Thread.new {
      begin
	timeout(SmallDelay) { sleep }
      rescue FrugalTimeout::Error
	arMutex.synchronize { ar << SmallDelay }
      end
    }
    sleep 0.1 until arMutex.synchronize { ar.size == 2 }
    ar.first.should == SmallDelay
    ar.last.should == LargeDelay
  end

  it 'handles lowering timeouts well' do
    multiple_timeouts false, 5
  end

  it 'handles growing timeouts well' do
    multiple_timeouts true, 5
  end

  it 'handles a lot of timeouts well' do
    res, resMutex = [], Mutex.new
    150.times {
      Thread.new {
	5.times { new_timeout_request 1, res, resMutex }
      }
    }
    sleep 1 until res.size == 750
    res.each { |sec| sec.round.should == 1 }
  end

  it 'handles new timeout well after sleep' do
    res, resMutex = [], Mutex.new
    new_timeout_request_thread 2, res, resMutex
    sleep 0.5
    new_timeout_request_thread 1, res, resMutex
    sleep 1 until res.size == 2
    res.first.round.should == 1
    res.last.round.should == 2
  end

  it 'handles multiple consecutive same timeouts' do
    res, resMutex = [], Mutex.new
    (cnt = 5).times { new_timeout_request 1, res, resMutex }
    sleep 1 until res.size == cnt
    res.each { |sec| sec.round.should == 1 }
  end

  it 'handles multiple concurrent same timeouts' do
    res, resMutex = [], Mutex.new
    (cnt = 5).times { new_timeout_request_thread 1, res, resMutex }
    sleep 1 until res.size == cnt
    res.each { |sec| (sec - 1).should < 0.01 }
  end

  context 'recursive timeouts' do
    it 'works if recursive timeouts rescue thrown exception' do
      # A rescue block will only catch exception for the timeout() block it's
      # written for.
      expect {
	timeout(0.5) {
	  begin
	    timeout(1) {
	      begin
		timeout(2) { sleep }
	      rescue Timeout::Error
	      end
	    }
	  rescue Timeout::Error
	  end
	}
      }.to raise_error Timeout::Error
    end

    it 'raises exception if inner timeout is defused before it is enforced' do
      expect {
	timeout(0.05, IOError) {
	  FrugalTimeout.on_enforce { sleep 0.02 }
	  timeout(0.01) { }
	  FrugalTimeout.on_enforce
	  sleep 0.06
	}
      }.to raise_error IOError
    end

    context "doesn't raise second exception in the same thread" do
      before :all do
	FrugalTimeout.on_ensure { sleep 0.02 }
      end

      it 'when two requests expire close to each other' do
	expect {
	  timeout(0.02) {
	    timeout(0.01, IOError) { sleep }
	  }
	}.to raise_error IOError
      end

      it "when second request doesn't have a chance to start" do
	expect {
	  timeout(0.01, IOError) {
	    sleep
	    timeout(1) { sleep }
	  }
	}.to raise_error IOError
      end

      FrugalTimeout.on_ensure
    end
  end

  it 'finishes after N sec' do
    start = MonotonicTime.now
    expect { timeout(1) { sleep 2 } }.to raise_error FrugalTimeout::Error
    (MonotonicTime.now - start).round.should == 1

    start = MonotonicTime.now
    expect { timeout(1) { sleep 3 } }.to raise_error FrugalTimeout::Error
    (MonotonicTime.now - start).round.should == 1
  end

  it 'returns value from block' do
    timeout(1) { 10 }.should == 10
    timeout(1) { 20 }.should == 20
  end

  it 'passes timeout to block' do
    timeout(10) { |t| t }.should == 10
    timeout(20) { |t| t }.should == 20
  end

  it 'raises specified exception' do
    expect { timeout(0.1, IOError) { sleep } }.to raise_error IOError
  end

  it 'raises specified exception inside the block' do
    expect {
      timeout(0.01, IOError) {
	begin
	  sleep
	rescue IOError
	end
      }
    }.not_to raise_error
  end

  it "doesn't raise exception if there's no need" do
    timeout(1) { }
    sleep 2
  end

  it 'handles exception within timeout()' do
    begin
      timeout(1) { raise 'lala' }
    rescue
    end
    sleep 2
  end

  it 'handles already expired timeout well' do
    expect { timeout(SMALLEST_TIMEOUT) { sleep } }.to \
      raise_error FrugalTimeout::Error
  end

  it 'acts as stock timeout (can rescue the same exception)' do
    expect { timeout(SMALLEST_TIMEOUT) { sleep } }.to \
      raise_error Timeout::Error
  end

  it "doesn't enforce defused timeout" do
    expect {
      timeout(0.1) { }
      sleep 0.2
    }.not_to raise_error
  end
end

# {{{1 MonotonicTime
describe FrugalTimeout::MonotonicTime do
  it 'ticks properly' do
    start = MonotonicTime.now
    sleep 0.1
    (MonotonicTime.now - start).round(1).should == 0.1
  end

  it '#measure works' do
    sleptFor = MonotonicTime.measure { sleep 0.5 }
    sleptFor.round(1).should == 0.5
  end
end

# {{{1 Request
describe FrugalTimeout::Request do
  it '#defuse! and #defused? work' do
    req = FrugalTimeout::Request.new(Thread.current,
      MonotonicTime.now, FrugalTimeout::Error)
    req.defused?.should == false
    req.defuse!
    req.defused?.should == true
  end
end

# {{{1 RequestQueue
describe FrugalTimeout::RequestQueue do
  before :each do
    @ar = []
    @requests = FrugalTimeout::RequestQueue.new
    @requests.onNewNearestRequest { |request|
      @ar << request
    }
  end

  context 'always invokes callback after purging' do
    [[10, "didn't expire yet"], [0, 'expired']].each { |sec, msg|
      it "when request #{msg}" do
	req = @requests.queue(sec, FrugalTimeout::Error)
	@ar.size.should == 1
      end
    }
  end
end

# {{{1 SleeperNotifier
describe FrugalTimeout::SleeperNotifier do
  before :all do
    @queue = Queue.new
    @sleeper = FrugalTimeout::SleeperNotifier.new
    @sleeper.onExpiry { @queue.push '.' }
  end

  def addRequest sec
    @sleeper.expireAt MonotonicTime.now + sec
  end

  it 'sends notification after delay passed' do
    start = MonotonicTime.now
    addRequest 0.5
    @queue.shift
    (MonotonicTime.now - start - 0.5).round(2).should <= 0.01
  end

  it 'handles negative delay' do
    MonotonicTime.measure {
      addRequest -1
      @queue.shift
    }.round(1).should == 0
  end

  it 'sends notification one time only for multiple requests' do
    5.times { addRequest 0.5 }
    start = MonotonicTime.now
    @queue.shift
    (MonotonicTime.now - start).round(1).should == 0.5
    @queue.should be_empty
  end

  it 'can stop current request by sending nil' do
    addRequest 0.5
    @sleeper.expireAt nil
    sleep 0.5
    @queue.should be_empty
  end

  it 'can setup onExpiry again and not break' do
    @sleeper.onExpiry
    addRequest 0.01
    # An exception here would be thrown in a different thread in case of a
    # problem.
  end
end

# {{{1 SortedQueue
describe FrugalTimeout::SortedQueue do
  before :each do
    @queue = FrugalTimeout::SortedQueue.new
  end

  it 'allows to push items into queue' do
    item = 'a'
    @queue.push item
    @queue.first.should == item
  end

  it 'supports << method' do
    @queue << 'a'
    @queue.first.should == 'a'
  end

  it 'makes first in order item appear first' do
    @queue.push 'b', 'a'
    @queue.first.should == 'a'
    @queue.last.should == 'b'
  end

  it 'allows removing items from queue' do
    @queue.push 'a', 'b', 'c'
    @queue.reject! { |item|
      next true if item < 'c'
      break
    }
    @queue.size.should == 1
    @queue.first.should == 'c'
  end

  it "doesn't sort underlying array if pushed values are first in order" do
    ar = double
    class MockArray < Array
      def sort!
	raise 'not supposed to call sort!'
      end
    end
    @queue = FrugalTimeout::SortedQueue.new MockArray.new
    expect {
      @queue.push 'c'
      @queue.push 'b'
      @queue.push 'a'
      @queue.first == 'a'
    }.not_to raise_error
  end

  it '#reject_and_get!' do
    @queue.push 'a'
    @queue.push 'b'
    res = @queue.reject_and_get! { |el| el < 'b' }
    res.size.should == 1
    res.first.should == 'a'
  end
end

# {{{1 Storage
describe FrugalTimeout::Storage do
  before :each do
    @storage = FrugalTimeout::Storage.new
  end

  context 'for a single key' do
    it 'contains nothing at first' do
      @storage.get(1).should == nil
    end

    it 'stores single value as non-array' do
      @storage.set 1, 2
      @storage.get(1).should == 2
    end

    it 'stores 2 values as array' do
      @storage.set 1, 2
      @storage.set 1, 3
      @storage.get(1).should == [2, 3]
    end

    context 'removes single value' do
      it 'and nothing is left' do
	@storage.set 1, 2
	@storage.delete 1, 2
	@storage.get(1).should == nil
      end

      it 'and single value is left' do
	@storage.set 1, 2
	@storage.set 1, 3
	@storage.delete 1, 2
	@storage.get(1).should == 3
      end

      it 'and several values left' do
	@storage.set 1, 2
	@storage.set 1, 3
	@storage.set 1, 4
	@storage.delete 1, 2
	@storage.get(1).should == [3, 4]
      end
    end

    it 'removes everything if no value is given' do
      @storage.set 1, 2
      @storage.set 1, 3
      @storage.delete 1
      @storage.get(1).should == nil
    end

    it 'supports #[] as #get' do
      @storage.set 1, 2
      @storage[1].should == 2
    end
  end
end
