# frozen_string_literal: true

raise "Diesl requires Ruby 4.0.10, got #{RUBY_VERSION}" unless RUBY_VERSION == "4.0.10"

require "js"
require "diesl"
require "application"

DieslBrowser::Application.new.start
