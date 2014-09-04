#!/usr/bin/env ruby

require 'rspec'
require 'spec_helper'
require 'frugal_timeout'

FrugalTimeout.dropin!
Thread.abort_on_exception = true

SMALLEST_TIMEOUT = 0.0000001

# {{{1 Helper methods
class Array
  def avg
    inject(:+)/size
  end
end

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
  start = MonotonicTime.now
  timeout(sec) { sleep }
rescue FrugalTimeout::Error
  resMutex.synchronize { res << MonotonicTime.now - start }
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
    res.avg.round.should == 1
  end

  it 'handles multiple concurrent same timeouts' do
    res, resMutex = [], Mutex.new
    (cnt = 5).times { new_timeout_request_thread 1, res, resMutex }
    sleep 1 until res.size == cnt
    (res.avg - 1).should < 0.01
  end

  context 'recursive timeouts' do
    it 'with the same delay' do
      expect {
	timeout(SMALLEST_TIMEOUT) {
	  timeout(SMALLEST_TIMEOUT) { sleep }
	}
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

  # Actually, there's a race here, but if timeout exception is raised, it's ok,
  # it just means it was faster than the block exception.
  it "doesn't raise timeout exception when block raises exception" do
    FrugalTimeout.on_ensure { sleep 0.02 }
    expect {
      timeout(0.01) { raise IOError }
    }.to raise_error IOError
    FrugalTimeout.on_ensure
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

