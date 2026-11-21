# frozen_string_literal: true

require "view_load_paths"
# Resolve ordinary require "json" to our pure upstream implementation before
# RubyGems / ActionView pull in incompatible native-extension wrappers.
require "verify_json"
require "/src/retro_ui/lib/retro_ui/rails/erb_compat"
require "action_view"
# ViewComponent 4.5.0 uses Rails::VERSION when compiling ERB templates.
# railties provides this real version module without booting Rails itself.
require "rails/version"
raise "Rails version mismatch" unless Rails::VERSION::STRING == "8.1.4.1"
require "view_component"
require "/src/retro_ui/lib/retro_ui/rails/class_names"

# These are the real component classes and colocated ERB templates from the
# pinned meleneth/retroui-rails repository, not a Diesl reimplementation.
%w[card card_header card_title card_content button input label select textarea].each do |kind|
  require "/src/retro_ui/app/components/retro_ui/rails/#{kind}_component"
end

module DieslBrowser
  module Components
    class Inspector < ViewComponent::Base
      def initialize(schema:, records:)
        @schema = schema
        @records = records
      end

      def call
        helpers.safe_join(@records.map { |record| record_card(record) })
      end

      private

      def record_card(record)
        definition = @schema.entities.fetch(record.entity)
        render(RetroUI::Rails::CardComponent.new(html_options: {class: "record"})) do
          helpers.safe_join([
            render(RetroUI::Rails::CardHeaderComponent.new) do
              render(RetroUI::Rails::CardTitleComponent.new) { definition.label }
            end,
            render(RetroUI::Rails::CardContentComponent.new) do
              helpers.safe_join(definition.fields.filter_map { |field| field_row(record, field) })
            end
          ])
        end
      end

      def field_row(record, field)
        return unless record.values.key?(field.name)

        value = record.values.fetch(field.name)
        identifier = "diesl-#{record.entity}-#{record.id}-#{field.name}"
        label = render(RetroUI::Rails::LabelComponent.new(
          text: field.name.to_s.tr("_", " ").capitalize, for_id: identifier
        ))
        control = if !record.editable.fetch(field.name, false)
                    helpers.content_tag(:span, "Dynamic expression (read only)", class: "muted")
                  else
                    attrs = {
                      id: identifier, "data-entity": record.entity.to_s, "data-id": record.id,
                      "data-field": field.name.to_s, "data-type": field.type.to_s
                    }
                    if field.type == :boolean
                      render(RetroUI::Rails::SelectComponent.new(
                        options: [["True", "true"], ["False", "false"]],
                        selected: value.to_s, html_options: attrs
                      ))
                    else
                      render(RetroUI::Rails::InputComponent.new(
                        type: field.type == :integer ? :number : :text,
                        value: value.to_s, html_options: attrs
                      ))
                    end
                  end
        helpers.content_tag(:div, helpers.safe_join([label, control]), class: "field")
      end
    end

    class SourceEditor < ViewComponent::Base
      def initialize(source:)
        @source = source
      end

      def call
        render(RetroUI::Rails::TextareaComponent.new(
          value: @source, html_options: {id: "dsl-source", spellcheck: "false"}
        ))
      end
    end

    class Toolbar < ViewComponent::Base
      def call
        helpers.safe_join([
          render(RetroUI::Rails::ButtonComponent.new(
            label: "Undo", variant: :secondary, html_options: {id: "undo"}
          )),
          render(RetroUI::Rails::ButtonComponent.new(
            label: "Redo", variant: :secondary, html_options: {id: "redo"}
          ))
        ])
      end
    end
  end

  class ComponentRenderer
    def initialize
      @context = ActionView::Base.empty
    end

    def render(component)
      component.render_in(@context)
    end
  end
end
