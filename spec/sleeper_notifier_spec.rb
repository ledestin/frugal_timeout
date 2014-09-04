require 'spec_helper'
require './lib/frugal_timeout/sleeper_notifier'

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
