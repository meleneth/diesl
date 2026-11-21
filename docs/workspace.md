# Declarative browser workspaces

Diesl's editor DSL can now declare a workspace without embedding persistence
or Git implementation code in the domain:

```ruby
EDITOR = Diesl::Editor.define do
  workspace do
    root "/workspace"
    source "mobilis.rb", last_valid: ".mobilis/last-valid.rb"
    storage :browser
    git branch: "main", author_name: "Mobilis Playground",
      author_email: "playground@mobilis.local"
    generated "generate"
    embedded :embedded_archive, codec: Mobilis::EmbeddedArchive
  end
  # entity declarations ...
end
```

The workspace is a frozen `Diesl::Workspace`. Its `manifest` is
JSON-compatible and contains only stable, declarative policy: file paths, store
type, Git branch and author, generated output roots, and embedded call names.
Codec objects remain Ruby-side and are deliberately not serialized.

The platform workspace adapter is responsible for creating directories,
storing source and last-valid snapshots, committing Git revisions, writing
generated files atomically, and routing embedded member edits through a
revision-guarded Ruby transaction. **The DSL declaration itself never does
I/O, runs Git, or evaluates user source.**

As of this change the constellation browser consumes the declared source path
and the editor exposes the full workspace manifest to adapters. A complete
LightningFS/isomorphic-git adapter is a separate implementation step, not
something this schema-only milestone claims has shipped.
