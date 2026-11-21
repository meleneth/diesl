# frozen_string_literal: true

module Diesl
  # Immutable domain-neutral workspace policy. It describes *what* the browser
  # workspace owns; a browser adapter supplies storage and Git operations.
  # Never evaluate source or perform filesystem side effects during definition.
  class Workspace
    SourceFile = Data.define(:path, :last_valid)
    Git = Data.define(:branch, :author_name, :author_email)
    Embedded = Data.define(:call, :codec, :editable)
    Generated = Data.define(:path)

    attr_reader :root, :source, :git, :generated, :embedded, :storage

    def initialize(root:, source:, storage:, git:, generated:, embedded:)
      @root = root.freeze
      @source = source
      @storage = storage
      @git = git
      @generated = generated.freeze
      @embedded = embedded.freeze
      freeze
    end

    # JSON-compatible and free of executable adapter objects. Intended to
    # cross the Ruby/WASM -> browser transport boundary.
    def manifest
      {
        version: 1,
        root: root,
        source: {path: source.path, last_valid: source.last_valid},
        storage: storage.to_s,
        git: git && {branch: git.branch, author: {name: git.author_name, email: git.author_email}},
        generated: generated.map { |item| {path: item.path} },
        embedded: embedded.map { |item| {call: item.call.to_s, editable: item.editable} }
      }
    end

    class Builder
      def initialize
        @root = "/workspace"
        @source = nil
        @storage = :browser
        @git = nil
        @generated = []
        @embedded = []
      end

      def root(path)
        @root = self.class.path!(path, absolute: true)
      end

      def source(path, last_valid: ".diesl/last-valid.rb")
        raise ArgumentError, "Workspace source already declared" if @source

        source_path = self.class.path!(path)
        last_valid_path = self.class.path!(last_valid)
        raise ArgumentError, "Source and last-valid paths must differ" if source_path == last_valid_path

        @source = SourceFile.new(path: source_path, last_valid: last_valid_path)
      end

      def storage(kind)
        kind = kind.to_sym
        raise ArgumentError, "Unsupported workspace storage: #{kind}" unless kind == :browser

        @storage = kind
      end

      def git(branch: "main", author_name:, author_email:)
        raise ArgumentError, "Git already declared" if @git
        raise ArgumentError, "Invalid Git branch" unless branch.is_a?(String) &&
          branch.match?(/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/) &&
          !branch.include?("..") && !branch.include?("//") &&
          !branch.end_with?("/", ".", ".lock") && !branch.start_with?("-")
        [author_name, author_email].each do |value|
          raise ArgumentError, "Git author fields must be nonempty strings" unless value.is_a?(String) &&
            !value.strip.empty? && !value.include?("\n")
        end

        @git = Git.new(branch: branch.dup.freeze, author_name: author_name.dup.freeze,
          author_email: author_email.dup.freeze)
      end

      def generated(path)
        path = self.class.path!(path)
        raise ArgumentError, "Duplicate generated path: #{path}" if @generated.any? { |item| item.path == path }

        @generated << Generated.new(path: path)
      end

      def embedded(call, codec:, editable: true)
        call = call.to_sym
        raise ArgumentError, "Duplicate embedded call: #{call}" if @embedded.any? { |item| item.call == call }
        raise ArgumentError, "Invalid embedded call" unless call.to_s.match?(/\A[a-z_][a-z_0-9]*[!?]?\z/)
        raise ArgumentError, "Codec must implement #entries and #replace" unless codec.respond_to?(:entries) && codec.respond_to?(:replace)
        raise ArgumentError, "Editable must be boolean" unless [true, false].include?(editable)

        @embedded << Embedded.new(call:, codec:, editable:)
      end

      def build
        raise ArgumentError, "Workspace must declare its source file" unless @source
        reserved = [@source.path, @source.last_valid, ".git", ".gitignore"]
        @generated.each do |item|
          if reserved.any? { |path| path == item.path || path.start_with?("#{item.path}/") || item.path.start_with?("#{path}/") } ||
              @generated.any? { |other| other != item && (other.path.start_with?("#{item.path}/") || item.path.start_with?("#{other.path}/")) }
            raise ArgumentError, "Generated path overlaps workspace files: #{item.path}"
          end
        end

        Workspace.new(root: @root, source: @source, storage: @storage, git: @git,
          generated: @generated.dup, embedded: @embedded.dup)
      end

      def self.path!(path, absolute: false)
        raise ArgumentError, "Workspace path must be a string" unless path.is_a?(String)
        raise ArgumentError, "Workspace path contains NUL or backslash" if path.include?("\0") || path.include?("\\")
        raise ArgumentError, "Expected absolute workspace root" if absolute && !path.start_with?("/")
        raise ArgumentError, "Expected relative workspace path" if !absolute && path.start_with?("/")
        parts = path.split("/", -1)
        parts.shift if absolute
        raise ArgumentError, "Unsafe workspace path: #{path.inspect}" if parts.empty? ||
          parts.any? { |part| part.empty? || part == "." || part == ".." }
        raise ArgumentError, "Workspace path must not end with a separator" if path.end_with?("/")
        path.dup.freeze
      end
    end
  end
end
