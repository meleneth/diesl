# Browser interaction contract: Ruby owns the event loop

**Turbo Frame-style granularity, without Turbo or HTTP.**

Diesl runs as a resident **Ruby 4.0.10** VM compiled to WASM in the browser. The browser's JS/WASM host is a bootstrap and DOM capability provider, not a parallel state machine. No Rails application, controller, JSON-over-HTTP transport or JavaScript model of the DSL exists.

## Event flow

1. The user edits a ViewComponent-rendered field.
2. The native browser event reaches a Ruby handler using the Ruby WASM `js` bridge. The JS bridge provides access to DOM objects; there is no custom action router written in JavaScript.
3. The handler gathers an entity, declaration identifier, field, input value and the *revision of the source from which the field was rendered*.
4. `Diesl::Session#change` checks the revision, calls the declarative editor, and performs one Prism-located source transformation. Unsupported or computed Ruby values remain read-only.
5. The resulting `Session::Update` contains the new authoritative source, revision and projected records plus a minimal invalidation list.
6. A Ruby-side ViewComponent presenter re-renders affected regions, then updates the real DOM through the WASM `js` bridge. The JS runtime never interprets the domain schema or edits the Ruby DSL.

The authoring DSL and rendered components are Ruby. The **source string** is authoritative; DOM values are never a secondary state model. The UI can preserve focused elements and selection state, and should avoid replacing a component unnecessarily.

## Example semantic event

```ruby
session = Diesl::Session.new(schema: EDITOR, source: ruby_source)
record = session.records.first

update = session.change(
  entity: :ship, id: record.id, field: :crew, value: 6,
  expected_revision: session.revision
)

# Ruby-side presenter: render only update.refresh regions as actual
# ViewComponents and patch those DOM targets using the js bridge.
# The presenter is NOT implemented yet; do not claim it works.
```

`Session` is implemented and tested without requiring a DOM so the semantic event protocol is independently verifiable. The ViewComponent renderer and bridge listener remain gated by the already documented Nokogiri/WASI compatibility failure.

## Required lifecycle semantics

- Register event listeners once at initialization. No Ruby polling or timers.
- RubyVM is instantiated **once** and reused until page closure.
- Revision-guard stale events; no silent overwrite.
- Refuse unsupported AST rewrites rather than replacing a whole source document.
- Preserve an invalid source buffer exactly while displaying last-valid projections as stale.
- Undo/redo are structured source transactions, not DOM mutations.
- Measure Ruby invocation counts and semantic duration. Idle Ruby invocation count must remain unchanged.
- Render with **real ViewComponent** and reuse the Datawires component model. Do not create an ersatz ViewComponent substitute to make the demo appear complete.

## Outstanding blockers

Mobilis's `view_component_compatibility/README.md` documents that real ViewComponent 4.5.0 fails under the existing WASM runtime because the ActionView sanitizer chain reaches Nokogiri without a WASI-compatible native extension. Reproduce under Ruby **4.0.10** and solve the dependency before claiming a browser demo or rendering adapter works. Neither Rails nor Turbo is an acceptable workaround.
