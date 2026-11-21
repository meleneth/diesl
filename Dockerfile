ARG RUBY_WASM_RUNTIME_IMAGE="mobilis-playground-ruby-runtime:2.10.1-ruby-4.0.10-rails-8.1.4.1"
FROM ${RUBY_WASM_RUNTIME_IMAGE} AS ruby_runtime

FROM node:22-trixie AS node

FROM ruby:4.0.10-trixie AS builder
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*
COPY browser/Gemfile browser/Gemfile.native ./browser/
RUN cd browser && bundle install
# Pin and exercise the extracted Carbn gem in the actual Ruby 4.0.10 builder.
RUN cd browser && bundle exec ruby -rcarbn -e 'g = Carbn::Graph.define { state :count, initial: 1; derive(:double, from: [:count]) { |n| n * 2 }; region :view, depends_on: [:double] }; s = Carbn::Store.new(g); seen = []; s.subscribe { |regions, _| seen << regions }; s.set(:count, 2); raise "Carbn integration failed" unless s.get(:double) == 4 && seen == [[:view]]'
# Native ViewComponent checks must not activate the WASM-only json_pure gem.
COPY browser/scripts/verify_native_view_component.rb ./browser/scripts/verify_native_view_component.rb
RUN cd browser && BUNDLE_GEMFILE=/build/browser/Gemfile.native bundle install
RUN cd browser && BUNDLE_GEMFILE=/build/browser/Gemfile.native bundle exec ruby scripts/verify_native_view_component.rb
ARG RETROUI_REF=d9ab51ba6ed8a38333f12e498a2566dc45e860b4
RUN git clone --no-checkout https://github.com/meleneth/retroui-rails.git /opt/retroui-rails \
 && cd /opt/retroui-rails && git checkout --detach "${RETROUI_REF}"
COPY browser/package.json browser/package-lock.json ./browser/
RUN cd browser && npm ci
COPY lib ./lib
COPY examples ./examples
COPY browser ./browser
COPY --from=ruby_runtime /runtime/ruby+stdlib.wasm ./browser/runtime/ruby+stdlib.wasm
COPY --from=ruby_runtime /runtime/runtime.json ./browser/runtime/runtime.json
RUN node --experimental-default-type=module --test browser/test/workspace.test.mjs
RUN RETROUI_SOURCE=/opt/retroui-rails bash browser/scripts/build

FROM nginx:1.30.6-trixie
COPY browser/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /build/browser/public /usr/share/nginx/html
EXPOSE 80
