# frozen_string_literal: true

require "digest"

module Diesl
  # Domain adapters delegate transformations to an existing Ruby source model.
  # Neither the adapter nor its session assumes anything about the domain DSL.
  # The consumer explicitly whitelists public transformation methods.
  class SourceAdapter
    attr_reader :document_class, :operations

    def initialize(document_class:, operations:)
      raise ArgumentError, "Document class must support #new" unless document_class.respond_to?(:new)
      raise ArgumentError, "Operations must be a nonempty Hash" unless operations.is_a?(Hash) && !operations.empty?

      @document_class = document_class
      @operations = operations.to_h do |name, method_name|
        operation = name.to_sym
        method = method_name.to_sym
        raise ArgumentError, "Invalid operation name: #{operation}" unless operation.to_s.match?(/\A[a-z][a-z_0-9]*\z/)
        raise ArgumentError, "Adapter operation must be public: #{method}" unless document_class.public_instance_methods.include?(method)
        [operation, method]
      end.freeze
      raise ArgumentError, "Duplicate adapter operations" unless @operations.size == operations.size
      freeze
    end

    def revision(source)
      Digest::SHA256.hexdigest(source)
    end

    def analyze(source)
      document = document_class.new(source)
      analysis = document.analyze
      raise ArgumentError, "Domain analysis must respond to #valid? and #errors" unless analysis.respond_to?(:valid?) && analysis.respond_to?(:errors)
      analysis
    end

    def validate!(source)
      analysis = analyze(source)
      raise InvalidSource, Array(analysis.errors).join("\n") unless analysis.valid?
      analysis
    end

    # No transformation runs against an invalid draft. A mutation must produce
    # a valid domain model before it is accepted as the next authoritative source.
    def apply(source, operation:, expected_revision:, **arguments)
      raise Conflict, "Source revision changed" unless expected_revision == revision(source)
      method = operations.fetch(operation.to_sym) { raise UnsafeEdit, "Undeclared adapter operation: #{operation}" }
      validate!(source)
      changed = document_class.new(source).public_send(method, **arguments)
      raise UnsafeEdit, "Adapter operation must return Ruby source text" unless changed.is_a?(String)
      validate!(changed)
      changed
    end

    def session(source:)
      AdaptedSession.new(adapter: self, source:)
    end
  end

  # Domain-neutral transactional source session. An invalid typing buffer is
  # retained without destroying the last valid semantic projection.
  class AdaptedSession
    attr_reader :adapter, :source, :draft_source, :draft_error, :history

    def initialize(adapter:, source:)
      @adapter = adapter
      adapter.validate!(source)
      @source = source.dup.freeze
      @draft_source = @source
      @draft_error = nil
      @history = History.new
      @typing = false
    end

    def revision = adapter.revision(source)
    def analysis = adapter.analyze(source)
    def draft_valid? = draft_error.nil?

    def type_source(text, expected_revision:)
      guard!(expected_revision)
      proposed = String(text).dup.freeze
      begin
        adapter.validate!(proposed)
      rescue InvalidSource => error
        @draft_source = proposed
        @draft_error = error.message
        return false
      end

      @draft_source = proposed
      @draft_error = nil
      return false if proposed == source

      history.record(source, proposed, label: "Edit Ruby source", coalesce: @typing)
      @typing = true
      @source = proposed
      true
    end

    def end_source_edit
      @typing = false
    end

    def apply(operation:, expected_revision:, label: nil, **arguments)
      guard!(expected_revision)
      raise Conflict, "Resolve the invalid Ruby source draft before editing" unless draft_valid?

      end_source_edit
      changed = adapter.apply(source, operation:, expected_revision:, **arguments)
      return false if changed == source
      history.record(source, changed, label: label || operation.to_s)
      publish(changed)
      true
    end

    def undo
      end_source_edit
      unless draft_valid?
        @draft_source = source
        @draft_error = nil
        return true
      end
      publish(history.undo(source))
      true
    end

    def redo
      raise Conflict, "Resolve the invalid Ruby source draft before redoing" unless draft_valid?
      end_source_edit
      publish(history.redo(source))
      true
    end

    private

    def guard!(expected_revision)
      raise Conflict, "Source revision changed" unless expected_revision == revision
    end

    def publish(changed)
      adapter.validate!(changed)
      @source = changed.dup.freeze
      @draft_source = @source
      @draft_error = nil
    end
  end
end
