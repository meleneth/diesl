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
COPY browser/Gemfile ./browser/Gemfile
RUN cd browser && bundle install
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
RUN RETROUI_SOURCE=/opt/retroui-rails bash browser/scripts/build

FROM nginx:1.30.6-trixie
COPY browser/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /build/browser/public /usr/share/nginx/html
EXPOSE 80
