# frozen_string_literal: true

module Diesl
  # Declarative editor schema. No application DSL is executed.
  class Editor
    Field = Data.define(:name, :type, :required, :options)
    Entity = Data.define(:name, :label, :fields)
    Record = Data.define(:id, :entity, :values, :editable)

    class EntityBuilder
      def initialize(name, label:)
        @name = name.to_sym
        @label = label
        @fields = []
      end

      def field(name, type:, required: false, options: nil)
        kind = type.to_sym
        raise ArgumentError, "Unsupported field type: #{kind}" unless %i[string integer boolean symbol].include?(kind)
        raise ArgumentError, "Duplicate field: #{name}" if @fields.any? { |field| field.name == name.to_sym }
        @fields << Field.new(name: name.to_sym, type: kind, required:, options: options&.freeze)
      end

      def build
        Entity.new(name: @name, label: @label, fields: @fields.freeze)
      end
    end

    def self.define(&block)
      editor = new
      editor.instance_eval(&block)
      editor.freeze
    end

    def initialize
      @entities = {}
      @workspace = nil
    end

    def entity(name, label: name.to_s.capitalize, &block)
      raise ArgumentError, "Duplicate entity: #{name}" if @entities.key?(name.to_sym)
      builder = EntityBuilder.new(name, label:)
      builder.instance_eval(&block)
      @entities[name.to_sym] = builder.build
    end

    def entities = @entities.dup.freeze
    # Workspace is part of the editor definition, not a second app config.
    # With a block it declares the workspace; without a block it reads it.
    def workspace(&block)
      return @workspace unless block

      raise ArgumentError, "Workspace already declared" if @workspace
      builder = Workspace::Builder.new
      builder.instance_eval(&block)
      @workspace = builder.build
    end

    # Project supported literal call arguments into editor records.
    # Dynamic values are visible but are intentionally not writable.
    def inspect(source)
      document = Source.new(source)
      raise InvalidSource, document.errors.join("\n") unless document.valid?

      @entities.values.flat_map do |entity|
        document.calls(name: entity.name).map do |call|
          arguments = call.arguments&.arguments || []
          keyword = arguments.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
          values = {}
          editable = {}
          entity.fields.each do |field|
            node = if field.name == :name
                     arguments.find { |arg| !arg.is_a?(Prism::KeywordHashNode) }
                   else
                     keyword&.elements&.find { |pair| pair.key.respond_to?(:value) && pair.key.value.to_sym == field.name }&.value
                   end
            next unless node

            begin
              values[field.name] = document.literal(node)
              editable[field.name] = true
            rescue UnsafeEdit
              values[field.name] = :dynamic
              editable[field.name] = false
            end
          end
          Record.new(id: call.location.start_offset.to_s, entity: entity.name,
            values: values.freeze, editable: editable.freeze)
        end
      end
    end

    # Record ids are source byte offsets. Always pair them with a revision.
    def update(source, entity:, id:, field:, value:, expected_revision:)
      schema = @entities.fetch(entity.to_sym)
      field_schema = schema.fields.find { |item| item.name == field.to_sym }
      raise ArgumentError, "Unknown field: #{field}" unless field_schema

      document = Source.new(source)
      raise Conflict, "Source revision changed" unless document.revision == expected_revision
      call = document.calls(name: schema.name).find { |node| node.location.start_offset.to_s == id.to_s }
      raise Conflict, "Declaration moved or disappeared" unless call

      arguments = call.arguments&.arguments || []
      node = if field_schema.name == :name
               arguments.find { |arg| !arg.is_a?(Prism::KeywordHashNode) }
             else
               keyword = arguments.find { |arg| arg.is_a?(Prism::KeywordHashNode) }
               keyword&.elements&.find { |pair| pair.key.respond_to?(:value) && pair.key.value.to_sym == field_schema.name }&.value
             end
      raise UnsafeEdit, "Field must exist as a literal before it can be edited" unless node

      validate_value(field_schema, value)
      document.replace_literal(node, value, expected_revision:)
    end

    private

    def validate_value(field, value)
      klass = {string: String, integer: Integer, boolean: [TrueClass, FalseClass], symbol: Symbol}.fetch(field.type)
      raise ArgumentError, "Invalid #{field.name}: expected #{field.type}" unless Array(klass).any? { |k| value.is_a?(k) }
      raise ArgumentError, "#{field.name} cannot be empty" if field.required && value.respond_to?(:empty?) && value.empty?
      raise ArgumentError, "Invalid #{field.name}: not in allowed options" if field.options && !field.options.include?(value)
    end
  end
end
