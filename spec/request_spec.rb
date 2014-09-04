require 'monotonic_time'
require 'spec_helper'
require './lib/frugal_timeout/error'
require './lib/frugal_timeout/request'

describe FrugalTimeout::Request do
  before :each do
    @request = FrugalTimeout::Request.new(Thread.current,
      MonotonicTime.now, FrugalTimeout::Error)
  end

  it '#defuse! and #defused? work' do
    @request.defused?.should == false
    @request.defuse!
    @request.defused?.should == true
  end

  it 'is defused after enforcing' do
    expect { Thread.new { @request.enforce }.join }.to raise_error
    @request.defused?.should == true
  end
end
