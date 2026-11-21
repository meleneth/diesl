# frozen_string_literal: true

module Diesl
  # Semantic transaction coordinator for an event-driven browser editor.
  # Browser event adapters and ViewComponent rendering are separate dependencies.
  # Nothing here performs HTTP requests, evaluates domain Ruby, or polls.
  class Session
    Update = Data.define(:revision, :source, :records, :changed, :refresh)

    attr_reader :schema, :source, :history

    def initialize(schema:, source:)
      @schema = schema
      @source = String(source).dup.freeze
      @history = History.new
    end

    def revision = Source.new(source).revision
    def records = schema.inspect(source)

    # A user event supplies the previously rendered source revision and an
    # editable declaration id. Never trust a stale UI snapshot.
    def change(entity:, id:, field:, value:, expected_revision:)
      raise Conflict, "Source revision changed" unless expected_revision == revision

      changed_source = schema.update(source, entity:, id:, field:, value:,
        expected_revision:)
      transition(changed_source, label: "Edit #{entity}.#{field}")
    end

    def undo
      new_source = history.undo(source)
      transition_without_record(new_source)
    end

    def redo
      new_source = history.redo(source)
      transition_without_record(new_source)
    end

    private

    def transition(new_source, label:)
      return update(changed: false) if new_source == source

      history.record(source, new_source, label:)
      transition_without_record(new_source)
    end

    def transition_without_record(new_source)
      schema.inspect(new_source) # validate before publishing any state
      @source = new_source.freeze
      update(changed: true)
    end

    def update(changed:)
      # The projection describes which components need refreshing. The
      # ViewComponent adapter decides how to render each requested region.
      # No HTTP/Turbo transport layer is involved.
      Update.new(revision:, source:, records:, changed:,
        refresh: changed ? %i[source inspector] : [])
    end
  end
end
