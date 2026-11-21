# frozen_string_literal: true

require "diesl"

RSpec.describe Diesl::Workspace do
  let(:codec) do
    Class.new do
      def self.unpack(*) = []
      def self.replace(*) = ""
    end
  end

  it "declares workspace behavior through the editor DSL without I/O" do
    codec_class = codec
    editor = Diesl::Editor.define do
      workspace do
        root "/workspace"
        source "mobilis.rb", last_valid: ".mobilis/last-valid.rb"
        storage :browser
        git branch: "main", author_name: "Mobilis", author_email: "mobilis@example.test"
        generated "generate"
        embedded :embedded_archive, codec: codec_class
      end
      entity :postgres do
        field :name, type: :string
      end
    end

    manifest = editor.workspace.manifest
    expect(manifest[:source]).to eq(path: "mobilis.rb", last_valid: ".mobilis/last-valid.rb")
    expect(manifest[:git][:branch]).to eq("main")
    expect(manifest[:generated]).to eq([{path: "generate"}])
    expect(manifest[:embedded]).to eq([{call: "embedded_archive", editable: true}])
    expect(editor.workspace.embedded.first.codec).to eq(codec_class)
    expect(editor.workspace).to be_frozen
    expect(editor.workspace.manifest).not_to have_key(:codec)
  end

  it "rejects unsafe and overlapping workspace paths" do
    %w[../escape /absolute dir/../escape dir//bad dir/].each do |path|
      expect {
        Diesl::Editor.define { workspace { source path } }
      }.to raise_error(ArgumentError)
    end
    expect {
      Diesl::Editor.define do
        workspace do
          source "mobilis.rb"
          generated ".diesl"
        end
      end
    }.to raise_error(ArgumentError, /overlaps/)
  end

  it "rejects duplicate declarations and invalid Git identities" do
    expect {
      Diesl::Editor.define { workspace { source "source.rb"; source "again.rb" } }
    }.to raise_error(ArgumentError, /already declared/)
    expect {
      Diesl::Editor.define do
        workspace do
          source "source.rb"
          git branch: "../unsafe", author_name: "A", author_email: "a@example.test"
        end
      end
    }.to raise_error(ArgumentError)
    expect {
      Diesl::Editor.define { workspace { generated "files" } }
    }.to raise_error(ArgumentError, /source file/)
  end

  it "does not require every editor to declare a workspace" do
    editor = Diesl::Editor.define { entity(:ship) { field :name, type: :string } }
    expect(editor.workspace).to be_nil
  end

  it "does not accept an embedded codec lacking the required operations" do
    expect {
      Diesl::Editor.define do
        workspace do
          source "fleet.rb"
          embedded :tarball, codec: Object.new
        end
      end
    }.to raise_error(ArgumentError, /Codec/)
  end
end
