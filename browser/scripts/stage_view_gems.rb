#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler"
require "fileutils"

destination = ARGV.fetch(0)
load_paths = []
counts = {}

# These extensions are compiled into the dedicated WASM runtime. Never mix
# host gem Ruby sources with a separately compiled native extension.
runtime_owned = %w[bigdecimal json nokogiri prism racc]

# Only Ruby runtime code and the templates/configuration it consumes belong
# in the browser image. Rails generators, CLI fixtures, docs, and tests do not.
# This is deliberately narrower than copying every gem's entire lib tree.
allowed_extensions = %w[.rb .erb .rake .yml .yaml .json .xml .html .txt]
excluded_directories = %w[generators generator templates fixtures test tests spec specs docs documentation examples]
exclude = lambda do |relative|
  parts = relative.split(File::SEPARATOR)
  parts[0...-1].any? { |part| excluded_directories.include?(part) } ||
    !allowed_extensions.include?(File.extname(relative))
end

Bundler.load.specs.sort_by(&:name).each do |gem|
  if runtime_owned.include?(gem.name)
    puts "  runtime-owned: #{gem.name} (not staged)"
    next
  end
  gem.require_paths.each do |relative|
    source = File.join(gem.full_gem_path, relative)
    next unless Dir.exist?(source)

    target = File.join(destination, "gems", "#{gem.name}-#{gem.version}", relative)
    FileUtils.mkdir_p(target)
    count = 0
    Dir.glob(File.join(source, "**", "*"), File::FNM_DOTMATCH).sort.each do |original|
      next unless File.file?(original)
      next if File.symlink?(original)
      member = original.delete_prefix("#{source}/")
      next if exclude.call(member)

      copied = File.join(target, member)
      FileUtils.mkdir_p(File.dirname(copied))
      FileUtils.cp(original, copied)
      count += 1
    end
    load_paths << "/gems/#{gem.name}-#{gem.version}/#{relative}"
    counts[gem.name] = counts.fetch(gem.name, 0) + count
  end
end
File.write(File.join(destination, "src/app/view_load_paths.rb"),
  "# frozen_string_literal: true\n$LOAD_PATH.unshift(*#{load_paths.inspect})\n")
puts "Browser gem source (runtime files only):"
counts.sort_by { |_name, count| -count }.each do |name, count|
  puts "  #{name}: #{count}"
end
puts "Total staged gem files: #{counts.values.sum}"
