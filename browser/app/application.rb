# frozen_string_literal: true

require "editor"

module DieslBrowser
  # Temporary Ruby/WASM interaction smoke UI until the real ViewComponent gate
  # passes. Do not mistake this for the final component renderer.
  class Application
    def initialize
      default_source = File.read("/src/examples/constellation/#{EDITOR.workspace.source.path}")
      workspace = JS.global[:DieslWorkspace]
      stored = workspace[:hasBootstrapSource].to_s == "true" ? workspace[:bootstrapSource].to_s : nil
      previous = workspace[:bootstrapValidSource].to_s
      valid = [stored, previous, default_source].compact.find do |candidate|
        next false if candidate.strip.empty?
        begin
          EDITOR.inspect(candidate)
          true
        rescue Diesl::InvalidSource, Diesl::UnsafeEdit
          false
        end
      end
      @session = Diesl::Session.new(schema: EDITOR, source: valid)
      @session.type_source(stored, expected_revision: @session.revision) if stored && !stored.strip.empty? && stored != valid
      @handlers = []
      @error = nil
      @renderer = ComponentRenderer.new
    end

    def start
      @document = JS.global[:document]
      @document.call(:querySelector, "#app")[:innerHTML] = shell
      target("toolbar-region")[:innerHTML] = @renderer.render(Components::Toolbar.new)
      render_regions
      persist_source
      input_handler = proc { |event| handle_input(event) }
      change_handler = proc { |event| handle_change(event) }
      blur_handler = proc { |event| @session.end_source_edit if event[:target][:id].to_s == "dsl-source" }
      click_handler = proc { |event| click(event) }
      @document.addEventListener("input", &input_handler)
      @document.addEventListener("change", &change_handler)
      @document.addEventListener("focusout", &blur_handler)
      @document.addEventListener("click", &click_handler)
      @handlers.concat([input_handler, change_handler, blur_handler, click_handler])
    end

    private

    def shell
      '<header><h1>Diesl · Ruby 4.0.10 WASM</h1><span class="muted">Direct Ruby DOM events · no Rails server</span></header>' \
        '<p class="muted">Ruby-driven editing with real ViewComponent / RetroUI rendering.</p>' \
        '<div id="toolbar-region" class="toolbar"></div>' \
        '<button id="restore-demo" type="button">Restore demo document</button>' \
        '<section id="workspace-region"><h2>Workspace · Git</h2><p id="workspace-status" class="muted">Initializing…</p>' \
        '<div class="toolbar"><button id="workspace-stage">Stage all</button>' \
        '<input id="workspace-message" placeholder="Commit message" aria-label="Git commit message">' \
        '<button id="workspace-commit">Commit</button></div><ol id="workspace-history"></ol></section>' \
        '<div id="diagnostics"></div><div class="columns"><section><h2>Source DSL</h2><div id="source-region"></div></section>' \
        '<section><h2>Declarative editor</h2><div id="inspector-region"></div></section></div>'
    end

    def render_regions
      render_source
      render_inspector
      render_status
    end

    def render_source
      target("source-region")[:innerHTML] = @renderer.render(Components::SourceEditor.new(source: @session.draft_source))
    end

    def render_inspector
      target("inspector-region")[:innerHTML] = @renderer.render(
        Components::Inspector.new(schema: EDITOR, records: @session.records)
      )
      sync_inspector_disabled
    end

    def render_status
      if @session.draft_valid?
        status = @error ? %(<p role="status" class="error">#{escape(@error)}</p>) :
          '<p role="status" class="success">✓ Valid Ruby DSL · editor synchronized</p>'
      else
        status = %(<p role="status" class="error">✕ Invalid Ruby DSL · retaining last valid form</p>) +
          %(<pre class="error">#{escape(@session.draft_error)}</pre>)
      end
      target("diagnostics")[:innerHTML] = status +
        %(<p class="muted">last valid revision #{escape(@session.revision[0, 12])}</p>)
    end

    def sync_inspector_disabled
      controls = target("inspector-region").call(:querySelectorAll, "[data-field]")
      controls[:length].to_i.times do |index|
        controls.call(:item, index)[:disabled] = !@session.draft_valid?
      end
    end

    # Text inputs are semantic edits on every keystroke. Do not replace the
    # inspector DOM during input: doing so destroys focus, cursor position,
    # selection and IME composition. Only the source and status regions change.
    def handle_input(event)
      return if event[:isComposing].to_s == "true"

      element = event[:target]
      if element[:id].to_s == "dsl-source"
        result = @session.type_source(element[:value].to_s,
          expected_revision: @session.revision)
        @error = nil
        render_inspector if result.changed
        sync_inspector_disabled
        render_status
        persist_source
        return
      end

      return unless element[:tagName].to_s == "INPUT"

      edit_field(element)
    rescue ArgumentError, Diesl::Conflict, Diesl::UnsafeEdit, Diesl::InvalidSource => error
      @error = "#{error.class}: #{error.message}"
      render_status
    end

    # Select controls fire change rather than per-keystroke input edits.
    # Text controls are already up to date by the time change fires.
    def handle_change(event)
      element = event[:target]
      edit_field(element) if element[:tagName].to_s == "SELECT"
    rescue ArgumentError, Diesl::Conflict, Diesl::UnsafeEdit, Diesl::InvalidSource => error
      @error = "#{error.class}: #{error.message}"
      render_status
    end

    def edit_field(element)
      raise Diesl::Conflict, "Resolve the invalid source before editing the form" unless @session.draft_valid?

      data = element[:dataset]
      entity = data[:entity].to_s
      return if entity.empty?

      field = data[:field].to_s
      value = element[:value].to_s
      typed = case data[:type].to_s
              when "integer" then Integer(value, 10)
              when "boolean" then value == "true"
              when "symbol" then value.to_sym
              else value
              end
      @session.change(entity: entity.to_sym, id: data[:id].to_s, field: field.to_sym,
        value: typed, expected_revision: @session.revision)
      @error = nil
      render_source
      sync_record_offsets
      render_status
      persist_source
    end

    # Prism IDs are byte offsets. Editing an earlier declaration moves later
    # declarations, so keep every existing form's data-id current in place.
    # This avoids rebuilding the active input on every keypress.
    def sync_record_offsets
      records = @session.records
      elements = @document.call(:querySelectorAll, ".record")
      return unless elements[:length].to_i == records.length

      records.each_with_index do |record, index|
        container = elements.call(:item, index)
        inputs = container.call(:querySelectorAll, "[data-id]")
        inputs[:length].to_i.times do |field_index|
          inputs.call(:item, field_index)[:dataset][:id] = record.id
        end
      end
    end

    def click(event)
      id = event[:target][:id].to_s
      return unless %w[undo redo restore-demo].include?(id)
      if id == "restore-demo"
        default_source = File.read("/src/examples/constellation/#{EDITOR.workspace.source.path}")
        @session = Diesl::Session.new(schema: EDITOR, source: default_source)
      else
        @session.public_send(id)
      end
      @error = nil
      render_regions
      persist_source
    rescue Diesl::Conflict, Diesl::InvalidSource => error
      @error = "#{error.class}: #{error.message}"
      render_status
    end

    def persist_source
      JS.global[:DieslWorkspace].call(:persistSource, @session.draft_source, @session.draft_valid?)
    end

    def target(id)
      @document.call(:getElementById, id)
    end

    def escape(value)
      value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&#39;")
    end
  end
end
