# Real ViewComponent / RetroUI browser renderer

Diesl uses `ViewComponent::Base#render_in` to render the actual component
classes and adjacent ERB templates from
[`meleneth/retroui-rails`](https://github.com/meleneth/retroui-rails).
The Docker build fetches the pinned repository revision
`d9ab51ba6ed8a38333f12e498a2566dc45e860b4`.

The Ruby source and gem dependencies are packaged into Diesl's existing
content-addressed WASI application TAR. Host-native binary extensions are
excluded. The Ruby 4.0.10 WASM interpreter still comes from the existing
separate Mobilis runtime image. There is **no Rails app or HTTP endpoint**.

`browser/app/view_components.rb` renders RetroUI cards, labels, inputs,
selects, a textarea, and buttons. Diesl's existing Ruby-side event handlers
continue to own live edits and source history.

**Compatibility is not verified yet.** ViewComponent loads ActionView, which
historically reached Nokogiri in Mobilis's compatibility probe. The pinned
runtime image has a native-extension compilation pipeline, but whether the
rendering dependency graph is functional must be tested in the actual browser.
The integration fails loudly rather than falling back to imitation components.
