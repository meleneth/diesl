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
end
