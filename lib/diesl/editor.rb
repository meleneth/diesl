# frozen_string_literal: true

module Diesl
  # Declarative editor schema. No application DSL is executed.
  class Editor
    Field = Data.define(:name, :type, :required, :options)
    Entity = Data.define(:name, :label, :fields, :creatable)
    Record = Data.define(:id, :entity, :values, :editable)

    class EntityBuilder
      def initialize(name, label:, creatable: false)
        @creatable = creatable
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
        Entity.new(name: @name, label: @label, fields: @fields.freeze, creatable: @creatable)
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
      @container = nil
      @source_adapter = nil
    end

    def entity(name, label: name.to_s.capitalize, creatable: false, &block)
      raise ArgumentError, "Duplicate entity: #{name}" if @entities.key?(name.to_sym)
      builder = EntityBuilder.new(name, label:, creatable:)
      builder.instance_eval(&block)
      @entities[name.to_sym] = builder.build
    end

    def entities = @entities.dup.freeze

    # Delegate semantic operations for complex DSLs to a declared domain adapter.
    # Existing simple editors continue using the built-in Prism transformations.
    def source_adapter(adapter = nil)
      return @source_adapter unless adapter
      raise ArgumentError, "Source adapter already declared" if @source_adapter
      raise ArgumentError, "Source adapter must support #analyze, #apply and #session" unless
        %i[analyze apply session].all? { |method| adapter.respond_to?(method) }
      @source_adapter = adapter
    end

    def adapted_session(source:)
      raise ArgumentError, "Editor has no source adapter" unless @source_adapter
      @source_adapter.session(source:)
    end

    def container(name = nil)
      return @container unless name
      raise ArgumentError, "Container already declared" if @container
      @container = name.to_sym
    end
    # Workspace is part of the editor definition, not a second app config.
    # With a block it declares the workspace; without a block it reads it.
    def workspace(&block)
      return @workspace unless block

      raise ArgumentError, "Workspace already declared" if @workspace
      builder = Workspace::Builder.new
      builder.instance_eval(&block)
      @workspace = builder.build
    end


    # Create new declarations only inside an explicitly configured do/end block.
    def create(source, entity:, name:, expected_revision:)
      schema = @entities.fetch(entity.to_sym)
      raise UnsafeEdit, "Creation not declared for #{entity}" unless schema.creatable
      raise ArgumentError, "Name is required" unless name.is_a?(String) && !name.strip.empty?
      raise UnsafeEdit, "No editor container declared" unless @container

      document = Source.new(source)
      raise Conflict, "Source revision changed" unless document.revision == expected_revision
      raise InvalidSource, document.errors.join("\n") unless document.valid?
      roots = document.calls(name: @container).select { |call| call.receiver.nil? && call.block }
      raise UnsafeEdit, "Expected one #{@container} block" unless roots.length == 1
      block = roots.first.block
      raise UnsafeEdit, "Expected do/end block" unless block.is_a?(Prism::BlockNode) && block.closing_loc

      offset = block.closing_loc.start_offset
      line_start = source.b.rindex("\n", offset - 1)
      line_start = line_start ? line_start + 1 : 0
      indentation = source.b.byteslice(line_start, offset - line_start)
      raise UnsafeEdit, "Container end must occupy its own line" unless indentation.match?(/\A[ \t]*\z/)
      values = schema.fields.filter_map do |field|
        next if field.name == :name
        default = case field.type
                  when :string then ""
                  when :integer then 0
                  when :boolean then false
                  when :symbol then :unset
                  end
        "#{field.name}: #{document.encode(default)}"
      end
      line = "#{indentation}  #{schema.name} #{document.encode(name)}"
      line += ", #{values.join(', ')}" unless values.empty?
      document.replace(line_start, line_start, line + "\n", expected_revision:)
    end

    def remove(source, entity:, id:, expected_revision:)
      schema = @entities.fetch(entity.to_sym)
      document = Source.new(source)
      raise Conflict, "Source revision changed" unless document.revision == expected_revision
      raise InvalidSource, document.errors.join("\n") unless document.valid?
      call = document.calls(name: schema.name).find { |item| item.location.start_offset.to_s == id.to_s }
      raise Conflict, "Declaration moved or disappeared" unless call
      raise UnsafeEdit, "Cannot remove nested/dynamic declaration" if call.receiver || call.block

      start_byte = call.location.start_offset
      end_byte = call.location.end_offset
      line_start = source.b.rindex("\n", start_byte - 1)
      line_start = line_start ? line_start + 1 : 0
      prefix = source.b.byteslice(line_start, start_byte - line_start)
      tail = source.b.byteslice(end_byte, source.bytesize - end_byte).to_s.split("\n", 2).first
      raise UnsafeEdit, "Declaration must occupy its own line" unless prefix.match?(/\A[ \t]*\z/) &&
        (tail.empty? || tail.match?(/\A[ \t]*#.*\z/))
      newline = source.b.index("\n", end_byte)
      document.replace(line_start, newline ? newline + 1 : source.bytesize, "", expected_revision:)
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
