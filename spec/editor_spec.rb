# frozen_string_literal: true

require "diesl"

RSpec.describe Diesl::Editor do
  let(:editor) do
    described_class.define do
      entity :ship do
        field :name, type: :string, required: true
        field :crew, type: :integer
        field :active, type: :boolean
      end

      entity :station do
        field :name, type: :string
      end
    end
  end

  let(:text) { "fleet do\n  ship 'Rocinante', crew: 4, active: true # keep\n  station 'Tycho'\nend\n" }

  it "projects two unrelated declarations using only the schema" do
    records = editor.inspect(text)
    expect(records.map(&:entity)).to eq(%i[ship station])
    expect(records.first.values).to eq(name: "Rocinante", crew: 4, active: true)
  end

  it "updates only the targeted literal preserving source trivia" do
    record = editor.inspect(text).first
    updated = editor.update(text, entity: :ship, id: record.id, field: :crew,
      value: 6, expected_revision: Diesl::Source.new(text).revision)
    expect(updated).to eq(text.sub("crew: 4", "crew: 6"))
  end

  it "preserves field defaults in the declarative schema and creates expressive blocks" do
    editor = described_class.define do
      container :fleet
      entity :ship, creatable: true do
        field :name, type: :string, required: true
        field :tags, type: :strings, default: ["scout", "explorer"]
      end
    end
    field = editor.entities.fetch(:ship).fields.find { |item| item.name == :tags }
    expect(field.default).to eq(["scout", "explorer"])
    expect(field.default).to be_frozen
    generated = editor.create("fleet do\nend\n", entity: :ship, name: "Rocinante",
      expected_revision: Diesl::Source.new("fleet do\nend\n").revision)
    expect(generated).to include('tags: ["scout", "explorer"]')
  end

  it "declares, edits, and validates string collection fields" do
    collection_editor = described_class.define do
      entity :warehouse do
        field :name, type: :string
        field :buckets, type: :strings
      end
    end
    original = 'warehouse "Tycho", buckets: ["ice", "water"]'
    record = collection_editor.inspect(original).first
    expect(record.values[:buckets]).to eq(["ice", "water"])
    changed = collection_editor.update(original, entity: :warehouse,
      id: record.id, field: :buckets, value: ["fuel", "medical"],
      expected_revision: Diesl::Source.new(original).revision)
    expect(changed).to eq('warehouse "Tycho", buckets: ["fuel", "medical"]')
    expect do
      collection_editor.update(original, entity: :warehouse, id: record.id,
        field: :buckets, value: ["fuel", 23],
        expected_revision: Diesl::Source.new(original).revision)
    end.to raise_error(ArgumentError, /array of strings/)
  end

  it "rejects wrong field types and stale source" do
    record = editor.inspect(text).first
    revision = Diesl::Source.new(text).revision
    expect { editor.update(text, entity: :ship, id: record.id, field: :crew,
      value: "six", expected_revision: revision) }.to raise_error(ArgumentError)
    expect { editor.update(text, entity: :ship, id: record.id, field: :crew,
      value: 6, expected_revision: "old") }.to raise_error(Diesl::Conflict)
  end

  it "shows dynamic fields without allowing their replacement" do
    source = "ship 'Rocinante', crew: compute_crew()\n"
    record = editor.inspect(source).first
    expect(record.values[:crew]).to eq(:dynamic)
    expect(record.editable[:crew]).to be(false)
    expect { editor.update(source, entity: :ship, id: record.id, field: :crew,
      value: 4, expected_revision: Diesl::Source.new(source).revision) }
      .to raise_error(Diesl::UnsafeEdit)
  end
  it "creates a declaration in an empty configured container and supports source-preserving deletion" do
    creator = described_class.define do
      container :fleet
      entity :ship, creatable: true do
        field :name, type: :string, required: true
        field :crew, type: :integer
      end
    end
    source = "fleet 'Empty' do\nend\n"
    created = creator.create(source, entity: :ship, name: "Rocinante",
      expected_revision: Diesl::Source.new(source).revision)
    expect(created).to eq("fleet 'Empty' do\n  ship \"Rocinante\", crew: 0\nend\n")
    record = creator.inspect(created).first
    expect(record.values).to eq(name: "Rocinante", crew: 0)
    removed = creator.remove(created, entity: :ship, id: record.id,
      expected_revision: Diesl::Source.new(created).revision)
    expect(removed).to eq(source)
  end

  it "rejects stale creates and declarations outside an editable block" do
    creator = described_class.define do
      container :fleet
      entity(:ship, creatable: true) { field :name, type: :string }
    end
    expect {
      creator.create("fleet do\nend\n", entity: :ship, name: "A", expected_revision: "stale")
    }.to raise_error(Diesl::Conflict)
    expect {
      creator.create("", entity: :ship, name: "A", expected_revision: Diesl::Source.new("").revision)
    }.to raise_error(Diesl::UnsafeEdit)
  end

  it "never creates an entity that has not opted into creation" do
    source = "fleet do\nend\n"
    expect {
      editor.create(source, entity: :ship, name: "A", expected_revision: Diesl::Source.new(source).revision)
    }.to raise_error(Diesl::UnsafeEdit)
  end

end
