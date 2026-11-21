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

  it "creates and removes declarations through the same undoable session" do
    editor = Diesl::Editor.define do
      container :fleet
      entity :ship, creatable: true do
        field :name, type: :string
        field :crew, type: :integer
      end
    end
    empty = "fleet do\nend\n"
    session = described_class.new(schema: editor, source: empty)
    result = session.create(entity: :ship, name: "Rocinante",
      expected_revision: session.revision)
    expect(result.records.length).to eq(1)
    record = result.records.first
    expect(record.values[:name]).to eq("Rocinante")
    expect(session.undo.source).to eq(empty)
    expect(session.redo.records.length).to eq(1)
    session.remove(entity: :ship, id: session.records.first.id,
      expected_revision: session.revision)
    expect(session.records).to be_empty
    expect(session.undo.records.length).to eq(1)
  end

end
