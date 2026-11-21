#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../../examples/constellation/editor"

source = File.read(File.expand_path("../../examples/constellation/fleet.rb", __dir__))
raise "Expected demo records" unless EDITOR.inspect(source).length == 3

empty = %(fleet "Empty" do\nend\n)
session = Diesl::Session.new(schema: EDITOR, source: empty)
raise "Empty container must project no records" unless session.records.empty?

created = session.create(entity: :ship, name: "Rocinante", expected_revision: session.revision)
raise "Create did not add exactly one record" unless created.records.length == 1
raise "Create did not preserve parent block" unless created.source.start_with?("fleet \"Empty\" do\n")
raise "Create did not write typed fields" unless created.records.first.values[:crew] == 0

session.undo
raise "Undo did not restore empty container" unless session.source == empty
session.redo
raise "Redo did not restore the ship" unless session.records.length == 1

session.remove(entity: :ship, id: session.records.first.id, expected_revision: session.revision)
raise "Delete did not restore empty source" unless session.source == empty

begin
  session.create(entity: :ship, name: "Stale", expected_revision: "stale")
  raise "Expected revision conflict"
rescue Diesl::Conflict
  # Good.
end

puts "Diesl source-backed create/remove and undo/redo smoke passed"
