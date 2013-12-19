#!/usr/bin/env ruby

require 'rspec'
require 'spec_helper'
require 'frugal_timeout'

FrugalTimeout.dropin!
Thread.abort_on_exception = true

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
    start = Time.now
    timeout(sec) { sleep }
  rescue FrugalTimeout::Error
    resMutex.synchronize { res << Time.now - start }
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
    it 'raises a single exception on same recursive timeouts' do
      expect {
	timeout(0.5) { timeout(0.5) { sleep } }
      }.to raise_error FrugalTimeout::Error
    end

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
  end

  it 'finishes after N sec' do
    start = Time.now
    expect { timeout(1) { sleep 2 } }.to raise_error FrugalTimeout::Error
    (Time.now - start).round.should == 1

    start = Time.now
    expect { timeout(1) { sleep 3 } }.to raise_error FrugalTimeout::Error
    (Time.now - start).round.should == 1
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
end

# {{{1 MonotonicTime
describe FrugalTimeout::MonotonicTime do
  it 'ticks properly' do
    start = FrugalTimeout::MonotonicTime.now
    sleep 0.1
    (FrugalTimeout::MonotonicTime.now - start).round(1).should == 0.1
  end

  it '#measure works' do
    sleptFor = FrugalTimeout::MonotonicTime.measure { sleep 0.5 }
    sleptFor.round(1).should == 0.5
  end
end

# {{{1 Request
describe FrugalTimeout::Request do
  it '#defuse! and #defused? work' do
    req = FrugalTimeout::Request.new(Thread.current,
      FrugalTimeout::MonotonicTime.now, FrugalTimeout::Error)
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
    req = FrugalTimeout::Request.new(Thread.current,
      FrugalTimeout::MonotonicTime.now + sec,
      FrugalTimeout::Error)
    @sleeper.sleepUntilExpires req
  end

  it 'sends notification after delay passed' do
    start = Time.now
    addRequest 0.5
    @queue.shift
    (Time.now - start - 0.5).round(2).should <= 0.01
  end

  it 'handles negative delay' do
    FrugalTimeout::MonotonicTime.measure {
      addRequest -1
      @queue.shift
    }.round(1).should == 0
  end

  it 'sends notification one time only for multiple requests' do
    5.times { addRequest 0.5 }
    start = Time.now
    @queue.shift
    (Time.now - start).round(1).should == 0.5
    @queue.should be_empty
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
