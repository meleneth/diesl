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

## Browser adapter

The Docker build now generates `workspace-config.json` directly from the
constellation editor's workspace DSL. `browser/public/workspace.js` consumes
the generated manifest before Ruby WASM boots. It uses LightningFS (IndexedDB)
and isomorphic-git, with no hardcoded application-specific source filename.

Implemented:
- Persistent authoritative source and separate last-valid source snapshot.
- Recover valid source, or recover invalid drafts without losing the prior form.
- Source edits, form edits, and undo/redo enqueue persistence in order.
- Git repository initialization, stage-all, commit, and a read-only history list.
- Atomic replacement of declared generated output roots via `persistGenerated`.
- Path validation and failure reporting on storage and Git operations.
- Node tests using fake filesystem/Git collaborators, run during Docker build.

Not yet implemented: embedded-archive member editor and history checkout.
`embedded` is schema-level metadata until a revision-guarded generic
archive-document transaction API is implemented. The generated-output storage
API is present, but the constellation demo has no generator to call it.

These changes have not been verified under the user's real browser runtime.
Run the Docker build and browser smoke test before treating this as parity
with Mobilis's existing workspace implementation.
