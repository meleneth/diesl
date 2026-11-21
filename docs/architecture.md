# Diesl browser architecture

Diesl is the extracted, domain-neutral authoring architecture from Mobilis's Ruby WASM playground.

```text
Browser (static assets only)
  JS: events + DOM lifecycle + persistent workspace + Git
  |
  | on semantic event
  v
Resident Ruby 4.0.10 WASM (idle between events)
  Diesl::Editor definition -> typed projection of Prism-located DSL source
  Diesl source transformations -> revision-guarded edits
  ViewComponent renderer -> HTML fragments
  |
  v
JS applies HTML updates; browser persists authoritative Ruby DSL source
```

## What to reuse

- Source editing and history: `meleneth/mobilis` `lib/mobilis/browser/source_document.rb`, `source_history.rb`, `virtual_document.rb` at `beware_of_scary_monsters`.
- Real Ruby/WASM application loading, resident RubyVM, browser event bridge, source-backed workspace: `mobilis/playground/`.
- **Datawires**: `app/components/drafts/projected_rows_component.*`, `projected_field_component.*`, `projected_section_component.*`, and `app/services/edit_affordances/projection.rb` (if present). Adapt the projection-to-ViewComponent boundary to Prism-backed Ruby source instead of JSON-document cursors.
- **RetroUI component library**: `meleneth/retroui-rails`, used by Datawires. It provides component presentation primitives but currently declares Rails, Stimulus and ViewComponent dependencies; this does **not** imply the whole gem boots without Rails in WASM.

## Mandatory compatibility gate

Mobilis `view_component_compatibility/README.md` records real ViewComponent 4.5.0 failing in WASM on 2026-11-20 because the ActionView sanitation dependency chain reaches loofah/Nokogiri and Nokogiri's host-native extension is not usable in WASI. Existing `render_probe.rb` and `probe_view_component_wasm.mjs` provide a starting point, not a passing result.

Before claiming a working browser editor:

1. Reproduce that test using the exact **Ruby 4.0.10** WASM runtime and the real ViewComponent implementation.
2. Resolve dependencies reproducibly for WASI rather than using host `.so` files, disabling sanitization or inserting a fake component renderer.
3. Test nested real components, escaped HTML output, an editor form, and application-owned events.
4. Measure runtime size, initial load, and no-work idle semantics.
5. Integrate the required subset of RetroUI's actual components or extract reusable ViewComponent primitives into a Rails-independent package, retaining their implementation and behavior.

No Rails HTTP process or Rails application is permitted. A framework gem required for ViewComponent/ActionView internals does not make the deployment Rails-backed; avoid importing Rails application/engine lifecycle.

## Product flow

`examples/constellation/fleet.rb` is the sample Ruby DSL and `examples/constellation/editor.rb` is its editor-definition DSL. They currently demonstrate **native source projection and editing only**; they do not yet render a browser editor. The browser integration must consume these exact definitions and then demonstrate a second unrelated DSL.

## Out of scope

Rails generators, Docker Compose service generation, a Vue rewrite, server-side data storage, duplicating the Datawires component model, and recreating prior compatibility investigations.

## Carbn extraction

Diesl consumes [Carbn](https://github.com/meleneth/carbn) as a pinned Git gem.
Carbn owns synchronous reactive transactions, declared region invalidation and
its real ViewComponent renderer; Diesl keeps Prism/source semantics, session
history, DSL schema, RetroUI component definitions and browser workspace/Git.
The browser uses Carbn's Store to refresh only affected regions, preventing
source-editor cursor loss on every input event. The legacy private
`ComponentRenderer` class has been removed.

The native Carbn core tests pass on Ruby 3.3. The WASM browser path still
requires smoke verification on the pinned Ruby 4.0.10 runtime.
