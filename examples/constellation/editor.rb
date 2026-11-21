# frozen_string_literal: true

require "diesl"

# An editor definition, NOT a reimplementation of the application DSL.
EDITOR = Diesl::Editor.define do
  entity :ship, label: "Starship" do
    field :name, type: :string, required: true
    field :class_name, type: :string
    field :crew, type: :integer
    field :active, type: :boolean
  end

  entity :station, label: "Station" do
    field :name, type: :string, required: true
    field :sector, type: :string
    field :active, type: :boolean
  end
end
