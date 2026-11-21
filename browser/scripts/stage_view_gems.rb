#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler"
require "fileutils"

destination = ARGV.fetch(0)
load_paths = []
Bundler.load.specs.sort_by(&:name).each do |gem|
  gem.require_paths.each do |relative|
    source = File.join(gem.full_gem_path, relative)
    next unless Dir.exist?(source)

    target = File.join(destination, "gems", "#{gem.name}-#{gem.version}", relative)
    FileUtils.mkdir_p(target)
    FileUtils.cp_r(Dir.glob(File.join(source, "*"), File::FNM_DOTMATCH).reject { |path|
      %w[. ..].include?(File.basename(path))
    }, target)
    # The WASM runtime carries native extensions, not the builder's Linux .so.
    Dir.glob(File.join(target, "**", "*.{so,bundle,dll}")).each { |path| File.delete(path) }
    load_paths << "/gems/#{gem.name}-#{gem.version}/#{relative}"
  end
end
File.write(File.join(destination, "src/app/view_load_paths.rb"),
  "# frozen_string_literal: true\n$LOAD_PATH.unshift(*#{load_paths.inspect})\n")
