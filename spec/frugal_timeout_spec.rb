#!/usr/bin/env ruby

require 'rspec'
require 'frugal_timeout'

FrugalTimeout.dropin!
Thread.abort_on_exception = true

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
    res.each { |sec| (sec - 1).should < 0.001 }
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
    expect { timeout(-1) { sleep } }.to raise_error FrugalTimeout::Error
  end

  it 'acts as stock timeout (can rescue the same exception)' do
    expect { timeout(-1) { sleep } }.to raise_error Timeout::Error
  end
end
