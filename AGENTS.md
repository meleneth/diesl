# Diesl architecture and engineering rules

## Product objective

Diesl is a generic browser-based editor for Ruby DSL source. Its own Ruby editor-definition DSL describes how to edit unrelated Ruby DSLs. The domain source remains authoritative.

## Non-negotiable runtime architecture

- **Ruby 4.0.10 only**, native for tests and `wasm32-wasi` for the browser runtime.
- Ruby executes **in the browser via WASM**. There is **no Rails server**, Rails application, server-backed controller, Vue frontend or JavaScript recreation of DSL semantics.
- **Real ViewComponent** is the rendering API. Reuse Datawires' projected editor component patterns and the existing `meleneth/retroui-rails` visual components where the WASM compatibility probes establish they work. Do not implement a bespoke UI component library.
- Treat the `retroui-rails` gem's Rails dependencies and engine as a compatibility issue to solve explicitly; the browser must never require booting Rails. Reuse or extract component code without claiming an untested gem loads in WASI.
- The browser JS layer owns DOM events, selection, file persistence, Git and incremental presentation only. The resident Ruby VM runs only for semantic operations, source validation and rendering; no Ruby polling.
- Preserve source through Prism byte-located conservative edits. Do not execute DSL Ruby merely to discover editable literal source ranges.
- Never touch Mobilis's Rails scaffolding, Docker images or generators as part of Diesl implementation.

## Integration gate already discovered

Mobilis `view_component_compatibility/README.md` on `beware_of_scary_monsters` documents a **failed** real ViewComponent 4.5.0 WASM probe (2026-11-20): ActionView sanitization requires loofah/Nokogiri, whose native extension was not present for WASI. Do not restart this research from zero, fake a ViewComponent with a proxy renderer, or declare ViewComponent/WASM working without running the gate under **Ruby 4.0.10**.

## Product acceptance

1. Define a sample domain DSL as real Ruby.
2. Declare its editable entities and fields with the Diesl editor-definition DSL.
3. Render a usable component-based browser editor via Ruby/WASM.
4. Perform AST-safe edits with revision checks and preserve source trivia.
5. Repeat with a second unrelated DSL without engine changes.
6. Test the real browser path, not merely native Ruby unit tests.
