# frozen_string_literal: true

module Diesl
  # The last valid source owns the form projection. A potentially invalid
  # authoring buffer is tracked separately and never destroys that projection.
  class Session
    Update = Data.define(:revision, :source, :records, :changed, :refresh)

    attr_reader :schema, :source, :history, :draft_source, :draft_error

    def initialize(schema:, source:)
      @schema = schema
      @source = String(source).dup.freeze
      schema.inspect(@source) # fail fast on an invalid initial document
      @draft_source = @source
      @draft_error = nil
      @source_typing = false
      @history = History.new
    end

    def revision = Source.new(source).revision
    def records = schema.inspect(source)
    def draft_valid? = draft_error.nil?

    # Called for every input event from the raw Ruby editor. A transient syntax
    # error is not a published edit, and the last valid form stays intact.
    # Once the buffer is valid, it is entered into structured undo history.
    def type_source(text, expected_revision:)
      raise Conflict, "Source revision changed" unless expected_revision == revision

      proposed = String(text).dup.freeze
      begin
        schema.inspect(proposed)
      rescue InvalidSource, UnsafeEdit => error
        @draft_source = proposed
        @draft_error = "#{error.class}: #{error.message}"
        return update(changed: false)
      end

      @draft_source = proposed
      @draft_error = nil
      if proposed == source
        return update(changed: false)
      end

      history.record(source, proposed, label: "Edit Ruby source", coalesce: @source_typing)
      @source_typing = true
      @source = proposed
      update(changed: true)
    end

    # Call on source editor blur to end a human-scale undo transaction.
    def end_source_edit
      @source_typing = false
    end

    def change(entity:, id:, field:, value:, expected_revision:)
      raise Conflict, "Resolve the invalid Ruby source draft before editing the form" unless draft_valid?
      raise Conflict, "Source revision changed" unless expected_revision == revision

      end_source_edit
      changed_source = schema.update(source, entity:, id:, field:, value:, expected_revision:)
      transition(changed_source, label: "Edit #{entity}.#{field}")
    end

    def undo
      end_source_edit
      unless draft_valid?
        @draft_source = source
        @draft_error = nil
        return update(changed: true)
      end
      new_source = history.undo(source)
      transition_without_record(new_source)
    end

    def redo
      raise Conflict, "Resolve the invalid Ruby source draft before redoing" unless draft_valid?

      end_source_edit
      new_source = history.redo(source)
      transition_without_record(new_source)
    end

    private

    def transition(new_source, label:)
      return update(changed: false) if new_source == source

      schema.inspect(new_source)
      history.record(source, new_source, label:)
      transition_without_record(new_source)
    end

    def transition_without_record(new_source)
      schema.inspect(new_source)
      @source = new_source.dup.freeze
      @draft_source = @source
      @draft_error = nil
      update(changed: true)
    end

    def update(changed:)
      Update.new(revision:, source:, records:, changed:,
        refresh: changed ? %i[source inspector] : [])
    end
  end
end
