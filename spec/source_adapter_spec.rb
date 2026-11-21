# frozen_string_literal: true

require "spec_helper"
require "diesl"

RSpec.describe Diesl::SourceAdapter do
  class AdapterFixture
    Analysis = Data.define(:valid?, :errors, :model)
    def initialize(source) = (@source = source)
    def analyze
      if @source.include?("INVALID")
        Analysis.new(false, ["invalid domain"], nil)
      else
        Analysis.new(true, [], @source.split(","))
      end
    end
    def add(name:) = @source + ",#{name}"
    def delete(name:) = @source.split(",").reject { |entry| entry == name }.join(",")
  end

  subject(:adapter) { described_class.new(document_class: AdapterFixture, operations: {create: :add, remove: :delete}) }

  it "delegates to domain methods without copying their source algorithms" do
    source = "alpha"
    changed = adapter.apply(source, operation: :create, name: "beta", expected_revision: adapter.revision(source))
    expect(changed).to eq("alpha,beta")
    expect(adapter.analyze(changed).model).to eq(%w[alpha beta])
  end

  it "rejects stale revisions, unlisted operations, and invalid results" do
    expect { adapter.apply("alpha", operation: :create, name: "x", expected_revision: "stale") }.to raise_error(Diesl::Conflict)
    expect { adapter.apply("alpha", operation: :eval, expected_revision: adapter.revision("alpha")) }.to raise_error(Diesl::UnsafeEdit)
    expect { adapter.apply("alpha", operation: :create, name: "INVALID", expected_revision: adapter.revision("alpha")) }.to raise_error(Diesl::InvalidSource)
  end

  it "keeps source and semantic projections stable across invalid drafts" do
    session = adapter.session(source: "alpha")
    expect(session.type_source("INVALID", expected_revision: session.revision)).to be(false)
    expect(session.source).to eq("alpha")
    expect(session.draft_source).to eq("INVALID")
    expect(session.draft_valid?).to be(false)
    expect { session.apply(operation: :create, name: "x", expected_revision: session.revision) }.to raise_error(Diesl::Conflict)
    session.undo
    expect(session.draft_valid?).to be(true)
    expect(session.draft_source).to eq("alpha")
  end

  it "groups structured edits into undoable operations and refuses stale writes" do
    session = adapter.session(source: "alpha")
    expect(session.apply(operation: :create, name: "beta", expected_revision: session.revision)).to be(true)
    expect(session.analysis.model).to eq(%w[alpha beta])
    expect(session.undo).to be(true)
    expect(session.source).to eq("alpha")
    expect(session.redo).to be(true)
    expect(session.source).to eq("alpha,beta")
    expect { session.apply(operation: :remove, name: "beta", expected_revision: "stale") }.to raise_error(Diesl::Conflict)
  end

  it "requires an explicit method whitelist" do
    expect { described_class.new(document_class: AdapterFixture, operations: {unsafe: :instance_eval}) }.to raise_error(ArgumentError)
  end
end
