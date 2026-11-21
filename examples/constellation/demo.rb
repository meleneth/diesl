# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require_relative "editor"

source = File.read(File.join(__dir__, "fleet.rb"))
revision = Diesl::Source.new(source).revision

puts "Editor schema:"
EDITOR.entities.each_value do |entity|
  puts "  #{entity.label}: #{entity.fields.map(&:name).join(', ')}"
end

puts "\nSource declarations:"
EDITOR.inspect(source).each { |record| puts "  #{record.entity} #{record.values.inspect}" }

record = EDITOR.inspect(source).find { |item| item.entity == :ship }
edited = EDITOR.update(source, entity: :ship, id: record.id, field: :crew,
  value: 6, expected_revision: revision)
puts "\nEdited source (only the selected AST literal changed):"
puts edited
