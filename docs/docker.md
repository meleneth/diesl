# Docker / Compose: existing Mobilis Ruby WASM runtime

Diesl intentionally **reuses the already built Mobilis runtime artifact image**, not Mobilis's application container and not a new Ruby cross-compiler pipeline. This preserves the separate runtime/application images and the pinned Ruby **4.0.10** WASM build.

The default runtime image is:
`mobilis-playground-ruby-runtime:2.10.1-ruby-4.0.10-rails-8.1.4.1`.

On the machine where Mobilis's runtime image already exists:

```sh
docker image inspect mobilis-playground-ruby-runtime:2.10.1-ruby-4.0.10-rails-8.1.4.1
docker compose up --build
```

Browse http://localhost:8080. The build **fails** if the runtime image is absent, its metadata is not Ruby 4.0.10, or its SHA-256/size disagree with the WASM module. No Ruby 4.0.0 or CDN fallback occurs.

To select a compatible differently tagged artifact image:

```sh
DIESL_RUBY_RUNTIME_IMAGE=your-existing-ruby-4.0.10-runtime:tag docker compose up --build
```

If the image is absent, build it once from the existing Mobilis checkout using `bin/build-playground-runtime`, then return here. Do not rebuild Nokogiri or Rails while working on Diesl unless the existing artifact itself fails its integrity/compatibility checks.

## What this verifies

This first browser smoke test loads a real resident Ruby VM, executes Diesl's declarative editor schema and Prism source transformations, registers native browser event handlers directly in Ruby via `js`, and round-trips an edited starship crew value into the Ruby source view. It includes structured undo/redo and a revision display.

**Important gate:** The smoke UI deliberately uses temporary Ruby-rendered HTML, **not** a fake ViewComponent implementation. The real ViewComponent dependency path remains blocked/unverified for the compiled Ruby/WASI artifact. Do not count this as acceptance of the final ViewComponent-based UI, which must reuse Datawires's component patterns and RetroUI where viable.

No Rails server, no Ruby backend service, no Vue, and no custom JavaScript action router. nginx only serves the static assets.
