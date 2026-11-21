#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"

runtime_path, output = ARGV
abort "usage: build_runtime_config.rb RUBY_WASM_PATH OUTPUT" unless runtime_path && output

runtime_package = ENV.fetch("RUBY_WASM_RUNTIME_PACKAGE", "@ruby/4.0-wasm-wasi")
runtime_version = ENV.fetch("RUBY_WASM_RUNTIME_VERSION", "2.10.1")
default_url = "https://cdn.jsdelivr.net/npm/#{runtime_package}@#{runtime_version}/dist/ruby+stdlib.wasm"
runtime_url = ENV.fetch("RUBY_WASM_RUNTIME_URL", default_url)
runtime_metadata = JSON.parse(File.read(ENV.fetch("RUBY_WASM_RUNTIME_METADATA"))) 
abort "Ruby 4.0.10 required" unless runtime_metadata.fetch("ruby") == "4.0.10"
runtime = File.binread(runtime_path)
abort "WASM runtime does not match metadata" unless runtime_metadata.fetch("sha256") == Digest::SHA256.hexdigest(runtime) && runtime_metadata.fetch("size") == runtime.bytesize
digest = Digest::SHA256.digest(runtime)
config = {
  format: "diesl-browser-runtime",
  version: 1,
  runtime: {
    package: runtime_package,
    package_version: runtime_version,
    ruby_version: "4.0.10",
    url: runtime_url,
    size: runtime.bytesize,
    sha256: digest.unpack1("H*"),
    integrity: "sha256-#{[digest].pack("m0")}"
  },
  application_manifest_url: ENV.fetch("DIESL_APPLICATION_MANIFEST_URL", "/diesl-app-manifest.json")
}
File.write(output, JSON.generate(config) + "\n")
