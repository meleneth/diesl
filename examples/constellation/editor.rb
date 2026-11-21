# frozen_string_literal: true

require "diesl"

# An editor definition, NOT a reimplementation of the application DSL.
EDITOR = Diesl::Editor.define do
  workspace do
    root "/workspace"
    source "fleet.rb", last_valid: ".diesl/last-valid.rb"
    storage :browser
    git branch: "main", author_name: "Diesl Playground", author_email: "playground@diesl.local", stage: [:source]
    generated "generate"
  end

  container :fleet

  entity :ship, label: "Starship", creatable: true do
    field :name, type: :string, required: true
    field :class_name, type: :string
    field :crew, type: :integer
    field :active, type: :boolean
  end

  entity :station, label: "Station", creatable: true do
    field :name, type: :string, required: true
    field :sector, type: :string
    field :active, type: :boolean
  end
end
