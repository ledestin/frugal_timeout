require 'spec_helper'

require './lib/frugal_timeout/sorted_queue'

describe FrugalTimeout::SortedQueue do
  before :each do
    @queue = FrugalTimeout::SortedQueue.new
  end

  context '#push' do
    it 'adds item into queue' do
      item = 'a'
      @queue.push item
      @queue.size.should == 1
      @queue.first.should == item
    end

    it 'calls block if element is sorted to be first' do
      called = nil
      @queue.push(2) { |el| called = el }
      called.should == 2
      @queue.push(1) { |el| called = el }
      called.should == 1
    end

    it "doesn't call block if the pushed element is the same as first" do
      @queue.push 1
      called = nil
      @queue.push(1) { called = true }
      called.should be_nil
    end

    it "doesn't call block if element isn't sorted to be first" do
      @queue.push 1
      called = nil
      @queue.push(3) { |el| called = el }
      called.should == nil
    end

    it 'raises exception if block given for multiple pushed elements' do
      expect {
	@queue.push(1, 2) { }
      }.to raise_error ArgumentError
    end

    context 'sorting' do
      it 'makes first in order item to be sorted first' do
	@queue.push 'b', 'a'
	@queue.first.should == 'a'
	@queue.reject! { |item| item == 'a' }
	@queue.first.should == 'b'
	@queue.size.should == 1
      end

      context 'works correctly if pushed values are <= the first element' do
	it 'as a single #push call' do
	  @queue.push 'c', 'b', 'a'
	  ar = []
	  @queue.reject! { |el| ar << el }
	  ar.should == ['a', 'b', 'c']
	end

	it 'as multiple push calls' do
	  @queue.push 'c'
	  @queue.push 'b'
	  @queue.push 'a'
	  ar = []
	  @queue.reject! { |el| ar << el }
	  ar.should == ['a', 'b', 'c']
	end
      end

      it "doesn't sort underlying array if pushed values are first in order" do
	class MockArray < Array
	  def sort!
	    raise 'not supposed to call sort!'
	  end
	end
	queue = FrugalTimeout::SortedQueue.new MockArray.new
	expect {
	  queue.push 'c'
	  queue.push 'b'
	  queue.push 'a'
	  queue.first == 'a'
	  queue.reject! { true }
	}.not_to raise_error

	expect {
	  queue.push 'c', 'b', 'a'
	  queue.first == 'a'
	  queue.reject! {}
	}.not_to raise_error
      end
    end
  end

  it '#<< method is supported' do
    @queue << 'a'
    @queue.first.should == 'a'
  end

  it '#reject! works' do
    @queue.push 'a', 'b', 'c'
    @queue.reject! { |item|
      next true if item < 'c'
      break
    }
    @queue.size.should == 1
    @queue.first.should == 'c'
  end

  context '#reject_until_mismatch!' do
    it 'removes one of the elements and returns @queue' do
      @queue.push 'a', 'b'
      @queue.reject_until_mismatch! { |el| el < 'b' }.should == @queue
      @queue.size.should == 1
      @queue.first.should == 'b'
    end

    it "doesn't remove any elements and returns nil" do
      @queue.push 'a', 'b'
      @queue.reject_until_mismatch! { }.should == nil
      @queue.size.should == 2
    end
  end

  context 'callbacks' do
    it 'calls on_add callback' do
      called = nil
      @queue.on_add { |el| called = el }
      @queue.push 'a'
      called.should == 'a'
    end

    it 'calls on_remove callback' do
      called = nil
      @queue.on_remove { |el| called = el }
      @queue.push 'a'
      @queue.reject! { |el| true }
      called.should  == 'a'
    end
  end
end
