# frozen_string_literal: true

# This file is loaded inside the actual browser Ruby WASM VM before ActionView.
# It exercises the upstream pure JSON implementation without touching the
# incompatible WASM C extension.
require "view_load_paths"
$LOAD_PATH.unshift("/src/app")
require "json"
raise "Unexpected JSON backend" unless defined?(JSON::Pure::Parser)
raise "JSON parse failed" unless JSON.parse('{"answer":42}') == {"answer" => 42}
raise "JSON generate failed" unless JSON.generate({"answer" => 42}) == '{"answer":42}'
