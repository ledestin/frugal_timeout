require 'spec_helper'
require './lib/frugal_timeout/hookable'

describe FrugalTimeout::Hookable do
  before :all do
    class Foo
      include MonitorMixin
      include FrugalTimeout::Hookable

      def initialize
	super
	def_hook :onBar, :onBar2
	def_hook_synced :onBarSynced, :onBarSynced2
      end

      def run
	@onBar.call
	@onBar2.call
	@onBarSynced.call
	@onBarSynced2.call
      end
    end

    @foo = Foo.new
  end

  it 'works w/o user-defined hook' do
    expect { @foo.run }.not_to raise_error
  end

  it 'calls user-defined hook' do
    called = called2 = nil
    @foo.onBar { called = true }
    @foo.onBar2 { called2 = true }
    @foo.run
    called.should == true
    called2.should == true
  end
end
