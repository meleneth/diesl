# frozen_string_literal: true

require "diesl"

RSpec.describe Diesl::Source do
  let(:source) { described_class.new("config('old', enabled: true) # keep this comment\n") }

  it "discovers calls without executing the DSL" do
    expect(source.calls(name: :config).length).to eq(1)
    expect(source.valid?).to be(true)
  end

  it "only exposes root DSL entrypoints, not nested calls with the same method" do
    document = described_class.new(<<~RUBY)
      Mobilis::DSL.build("outer") do
        helper = build("inner")
      end
    RUBY
    expect(document.root_calls(name: :build).length).to eq(1)
    expect(document.calls(name: :build).length).to eq(2)
  end

  it "traverses nested calls without mistaking nested declarations for direct block statements" do
    document = described_class.new(<<~RUBY)
      fleet do
        ship "Rocinante", crew: 4, tags: ["ice", "belt"]
        group do
          ship "Nested"
        end
      end
    RUBY
    root = document.calls(name: :fleet).first
    expect(document.calls(name: :ship, within: root.block).length).to eq(2)
    expect(document.direct_calls(within: root.block, name: :ship).length).to eq(1)
    ship = document.direct_calls(within: root.block, name: :ship).first
    expect(document.keyword_values(ship)).to eq(crew: 4, tags: ["ice", "belt"])
    expect(document.keyword_elements(ship).map { |entry| document.keyword_name(entry) }).to eq(%i[crew tags])
  end

  it "makes enclosing block semantics explicit and prunes opaque nested DSL calls" do
    document = described_class.new(<<~RUBY)
      fleet do
        ship("Rocinante", name: "keeper")
        embedded_archive("opaque", payload: "keeper")
        group do
          ship("Nested")
        end
      end
    RUBY
    root = document.calls(name: :fleet).first
    expect(document.block_calls(container: root, name: :ship).length).to eq(1)
    names = document.nodes(
      within: root.block.body,
      prune: ->(node) { node.is_a?(Prism::CallNode) && node.name == :embedded_archive }
    ).grep(Prism::StringNode).map(&:unescaped)
    expect(names).to include("Rocinante", "keeper", "Nested")
    expect(names).not_to include("opaque")
  end

  it "marks dynamic keywords without executing them" do
    document = described_class.new('ship "Rocinante", crew: compute()')
    expect(document.keyword_values(document.calls(name: :ship).first)).to eq(crew: :dynamic)
  end

  it "finds entire edit lines in Prism byte coordinates even after multibyte comments" do
    text = "# 🪐 header\nship(\"mémoire\") # trailing\n"
    document = described_class.new(text)
    call = document.calls(name: :ship).first
    start_byte = call.location.start_offset
    end_byte = call.location.end_offset
    expect(document.line_start(0)).to eq(0)
    expect(document.line_start(start_byte)).to eq("# 🪐 header\n".bytesize)
    first, last = document.line_range(start_byte, end_byte)
    expect(text.b.byteslice(first, last - first).force_encoding("UTF-8"))
      .to eq("ship(\"mémoire\") # trailing\n")
  end

  it "preserves surrounding source exactly when changing a literal" do
    node = source.calls(name: :config).first.arguments.arguments.first
    expect(source.replace_literal(node, "new", expected_revision: source.revision))
      .to eq('config("new", enabled: true) # keep this comment' + "\n")
    expect(source.text).to include("'old'")
  end

  it "rejects revisions from a different source" do
    expect { source.replace(0, 0, "# note\n", expected_revision: "stale") }
      .to raise_error(Diesl::Conflict)
  end

  it "refuses computed values" do
    document = described_class.new("config(prefix + suffix)\n")
    node = document.calls(name: :config).first.arguments.arguments.first
    expect { document.replace_literal(node, "override", expected_revision: document.revision) }
      .to raise_error(Diesl::UnsafeEdit)
  end

  it "rejects replacements that would invalidate Ruby" do
    expect { source.replace(0, 6, "if", expected_revision: source.revision) }
      .to raise_error(Diesl::InvalidSource)
  end

  it "does not corrupt multibyte text when Prism gives byte offsets" do
    document = described_class.new("config('☃', enabled: true)\n")
    node = document.calls(name: :config).first.arguments.arguments.first
    expect(document.replace_literal(node, "☀", expected_revision: document.revision))
      .to eq("config(\"☀\", enabled: true)\n")
  end
end
