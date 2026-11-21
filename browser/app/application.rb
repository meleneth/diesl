# frozen_string_literal: true

require "json"
require_relative "../../examples/constellation/editor"

module DieslBrowser
  # Temporary Ruby/WASM interaction smoke UI until the real ViewComponent gate
  # passes. Do not mistake this for the final component renderer.
  class Application
    def initialize
      @session = Diesl::Session.new(schema: EDITOR, source: File.read("/src/examples/constellation/fleet.rb"))
      @handlers = []
      @error = nil
    end

    def start
      @document = JS.global[:document]
      @document.call(:querySelector, "#app")[:innerHTML] = shell
      render_regions
      change_handler = proc { |event| change(event) }
      click_handler = proc { |event| click(event) }
      @document.addEventListener("change", &change_handler)
      @document.addEventListener("click", &click_handler)
      @handlers.concat([change_handler, click_handler])
    end

    private

    def shell
      '<header><h1>Diesl · Ruby 4.0.10 WASM</h1><span class="muted">Direct Ruby DOM events · no Rails server</span></header>' \
        '<p class="muted">Ruby-driven source editing smoke test. ViewComponent renderer remains gated on Nokogiri/WASI.</p>' \
        '<div class="toolbar"><button id="undo">Undo</button><button id="redo">Redo</button></div>' \
        '<div id="diagnostics"></div><div class="columns"><section><h2>Source DSL</h2><div id="source-region"></div></section>' \
        '<section><h2>Declarative editor</h2><div id="inspector-region"></div></section></div>'
    end

    def render_regions
      render_source
      render_inspector
      render_status
    end

    def render_source
      target("source-region")[:innerHTML] = %(<textarea id="dsl-source" spellcheck="false">#{escape(@session.source)}</textarea>)
    end

    def render_inspector
      html = @session.records.map do |record|
        fields = EDITOR.entities.fetch(record.entity).fields.filter_map do |field|
          next unless record.values.key?(field.name)
          value = record.values.fetch(field.name)
          editable = record.editable.fetch(field.name, false)
          input = if !editable
                    %(<span class="muted">Dynamic expression (read only)</span>)
                  elsif field.type == :boolean
                    %(<select data-entity="#{record.entity}" data-id="#{record.id}" data-field="#{field.name}" data-type="boolean">) \
                      + [true, false].map { |v| %(<option value="#{v}"#{v == value ? ' selected' : ''}>#{v}</option>) }.join \
                      + '</select>'
                  else
                    %(<input data-entity="#{record.entity}" data-id="#{record.id}" data-field="#{field.name}" data-type="#{field.type}" type="#{field.type == :integer ? 'number' : 'text'}" value="#{escape(value)}">)
                  end
          %(<div class="field"><label>#{escape(field.name)}</label>#{input}</div>)
        end.join
        %(<div class="record"><strong>#{escape(record.entity)}</strong>#{fields}</div>)
      end.join
      target("inspector-region")[:innerHTML] = html
    end

    def render_status
      status = @error ? %(<p class="error">#{escape(@error)}</p>) : '<p class="success">Ruby session ready</p>'
      target("diagnostics")[:innerHTML] = status + %(<p class="muted">revision #{escape(@session.revision[0, 12])}</p>)
    end

    def change(event)
      element = event[:target]
      if element[:id].to_s == "dsl-source"
        @session = Diesl::Session.new(schema: EDITOR, source: element[:value].to_s)
        @error = nil
        render_inspector
        render_status
        return
      end
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
      render_regions
    rescue ArgumentError, Diesl::Conflict, Diesl::UnsafeEdit, Diesl::InvalidSource => error
      @error = "#{error.class}: #{error.message}"
      render_status
    end

    def click(event)
      id = event[:target][:id].to_s
      return unless %w[undo redo].include?(id)
      @session.public_send(id)
      @error = nil
      render_regions
    rescue Diesl::Conflict, Diesl::InvalidSource => error
      @error = "#{error.class}: #{error.message}"
      render_status
    end

    def target(id)
      @document.call(:getElementById, id)
    end

    def escape(value)
      value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&#39;")
    end
  end
end
