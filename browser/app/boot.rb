# frozen_string_literal: true

raise "Diesl requires Ruby 4.0.10, got #{RUBY_VERSION}" unless RUBY_VERSION == "4.0.10"

require "js"
require "diesl"
# The WASM interpreter does not eagerly initialize RubyGems. Nokogiri
# 1.19.7 uses Gem::Version while ActionView loads its sanitizer stack.
# Load the real RubyGems implementation before any renderer dependencies.
require "rubygems"
raise "RubyGems did not initialize Gem::Version" unless defined?(Gem::Version)
require "view_components"
require "application"

DieslBrowser::Application.new.start
