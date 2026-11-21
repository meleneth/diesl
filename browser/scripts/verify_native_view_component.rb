# frozen_string_literal: true

# This is a native CRuby check, deliberately separate from browser/WASM gem staging.
require "json"
raise "Native JSON parser unavailable" unless JSON.parse('{"ok":true}') == {"ok" => true}
raise "Native smoke activated json_pure" if defined?(JSON::Pure::Parser)

require "action_view"
require "rails/version"
require "view_component"
require "carbn"

class CarbnNativeRenderProbe < ViewComponent::Base
  def call
    helpers.content_tag(:strong, "Carbn")
  end
end

html = Carbn::ViewComponentRenderer.new.render(CarbnNativeRenderProbe.new)
raise "Carbn ViewComponent render mismatch: #{html.inspect}" unless html.include?("<strong>Carbn</strong>")
puts "Real native ViewComponent rendering via Carbn passed"
