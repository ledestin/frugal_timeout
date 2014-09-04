require 'spec_helper'
require './lib/frugal_timeout/storage'

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
