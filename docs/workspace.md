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
      author_email: "playground@mobilis.local", stage: [:generated]
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

The separate `browser/public/workspace-history.js` module now supplies
the reusable Git features needed by richer consumers:

- `createWorkspaceHistory` accepts domain-defined generation phases containing
  commit messages and binary Base64 file deltas. It checks paths, commits each
  phase into an independent Git repository, prepares both generated trees,
  publishes them with rollback, and exports the original Git objects.
- `createWorkspaceRevision` restores a selected commit only if the working
  tree is clean, calls the domain's validation callback, updates the last-valid
  snapshot, and rolls back a rejected checkout.
- `browser/public/git-capability.js` owns the low-level byte-accurate Git
  checkpoint primitive. Neither module assumes a Mobilis DSL or DOM UI.
- `browser/test/workspace-history.test.mjs` exercises phase history, export,
  invalid paths, mirror publication failure, dirty-tree protection, and
  rejected source restoration using a deterministic filesystem/Git double.

The default Diesl browser demo has no generation history or restore controls;
applications opt into these capabilities and supply their own validation and
UI events. The embedded-archive member editor is still application-owned.
`embedded` remains metadata until a generic archive transaction API is added.

These changes have not been verified under the user's real browser runtime.
Run the Docker build and browser smoke test before treating this as parity
with Mobilis's existing workspace implementation.

## Explicit Git policy

The `git` declaration requires `stage:` with `:source`, `:generated`, or both.
The constellation demo stages `fleet.rb` through `stage: [:source]`.
Mobilis should use `stage: [:generated]`, so `mobilis.rb` stays as an
uncommitted authoring input while the declared `generated "generate"` tree
is Git-versioned. Existing files outside the policy are never implicitly
staged; commits refuse already-staged files outside the policy.

The workspace UI lists the policy targets separately from the exact paths
currently in the index. A browser-side Git exception includes its stack for
debugging rather than only a generic error message.

## LightningFS flush contract

Use `fs.promises.flush()`. The callback-based `fs.flush(callback)` requires
an actual callback and otherwise raises `expected a function but got undefined`.
The Node workspace test now deliberately rejects callback-style flush, and the
integration test exercises isomorphic-git against the real LightningFS memory
backend. Both tests run in the Docker builder before packaging the application.
