# frozen_string_literal: true

# Sample user-owned Ruby DSL source.
fleet "Belt Patrol" do
  ship "Rocinante", class_name: "Corvette", crew: 4, active: true
  ship "Canterbury", class_name: "Ice hauler", crew: 50, active: false
  station "Tycho", sector: "Belt", active: true
end
