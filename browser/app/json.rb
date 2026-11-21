# frozen_string_literal: true

# Select the official json_pure gem for the browser runtime. Ruby's built-in
# JSON C extension and the JSON 3.1.0 Ruby gem sources are not API-compatible
# in our existing WASM artifact. Do not patch, monkeypatch, or load json/ext.
require "json/pure"
