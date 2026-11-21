# frozen_string_literal: true

require "diesl"

RSpec.describe Diesl::Session do
  let(:editor) do
    Diesl::Editor.define do
      entity :ship do
        field :name, type: :string, required: true
        field :crew, type: :integer
      end
    end
  end
  let(:original) { "fleet do\n  ship 'Rocinante', crew: 4 # keep\nend\n" }
  let(:session) { described_class.new(schema: editor, source: original) }

  it "accepts one semantic edit and returns invalidated regions" do
    id = session.records.first.id
    result = session.change(entity: :ship, id:, field: :crew, value: 6,
      expected_revision: session.revision)
    expect(result.source).to eq(original.sub("crew: 4", "crew: 6"))
    expect(result.refresh).to eq(%i[source inspector])
    expect(result.revision).to eq(Diesl::Source.new(result.source).revision)
  end

  it "rejects stale UI events without changing source" do
    id = session.records.first.id
    expect { session.change(entity: :ship, id:, field: :crew,
      value: 6, expected_revision: "stale") }.to raise_error(Diesl::Conflict)
    expect(session.source).to eq(original)
  end

  it "supports semantic undo and redo without creating extra history entries" do
    id = session.records.first.id
    session.change(entity: :ship, id:, field: :crew, value: 6,
      expected_revision: session.revision)
    expect(session.undo.source).to eq(original)
    expect(session.redo.source).to include("crew: 6")
  end

  it "does not require a browser or Rails to exercise semantic transactions" do
    expect(session.records.first.values[:name]).to eq("Rocinante")
    expect(session.history.undo_entries).to be_empty
  end
end
