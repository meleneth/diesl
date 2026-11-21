# frozen_string_literal: true

require "diesl"

RSpec.describe "Ruby source drafts and structured history" do
  let(:editor) do
    Diesl::Editor.define do
      entity :ship do
        field :name, type: :string, required: true
        field :crew, type: :integer
      end
    end
  end
  let(:initial) { "fleet do\n  ship 'Rocinante', crew: 4\nend\n" }
  let(:session) { Diesl::Session.new(schema: editor, source: initial) }

  it "retains the last valid form while an incomplete Ruby draft is typed" do
    draft = initial.sub("crew: 4", "crew: ")
    result = session.type_source(draft, expected_revision: session.revision)
    expect(result.changed).to be(false)
    expect(result.refresh).to eq([])
    expect(session.draft_source).to eq(draft)
    expect(session.draft_valid?).to be(false)
    expect(session.source).to eq(initial)
    expect(session.records.first.values[:crew]).to eq(4)
    expect(session.history.undo_entries).to be_empty
  end

  it "promotes a repaired source draft into one undoable structured edit" do
    session.type_source(initial.sub("crew: 4", "crew: "), expected_revision: session.revision)
    changed = initial.sub("crew: 4", "crew: 6")
    result = session.type_source(changed, expected_revision: session.revision)
    expect(result.changed).to be(true)
    expect(session.draft_valid?).to be(true)
    expect(session.records.first.values[:crew]).to eq(6)
    expect(session.undo.source).to eq(initial)
    expect(session.redo.source).to eq(changed)
  end

  it "coalesces consecutive valid keystrokes until the source field loses focus" do
    first = initial.sub("crew: 4", "crew: 45")
    second = initial.sub("crew: 4", "crew: 456")
    session.type_source(first, expected_revision: session.revision)
    session.type_source(second, expected_revision: session.revision)
    expect(session.history.undo_entries.length).to eq(1)
    expect(session.undo.source).to eq(initial)
  end

  it "starts a new source history transaction after blur" do
    first = initial.sub("crew: 4", "crew: 5")
    second = initial.sub("crew: 4", "crew: 6")
    session.type_source(first, expected_revision: session.revision)
    session.end_source_edit
    session.type_source(second, expected_revision: session.revision)
    expect(session.history.undo_entries.length).to eq(2)
    expect(session.undo.source).to eq(first)
  end

  it "discards an invalid draft before undoing the last committed source edit" do
    session.type_source(initial.sub("crew: 4", "crew: 6"), expected_revision: session.revision)
    session.type_source(initial.sub("crew: 4", "crew: "), expected_revision: session.revision)
    expect(session.undo.source).to include("crew: 6")
    expect(session.draft_valid?).to be(true)
    expect(session.undo.source).to eq(initial)
  end

  it "disallows form mutations against an invalid source draft" do
    id = session.records.first.id
    session.type_source(initial.sub("crew: 4", "crew: "), expected_revision: session.revision)
    expect {
      session.change(entity: :ship, id:, field: :crew, value: 10,
        expected_revision: session.revision)
    }.to raise_error(Diesl::Conflict)
  end
end
