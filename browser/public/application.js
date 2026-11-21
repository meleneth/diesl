import { RubyVM } from "/vendor/ruby-wasm-wasi/vm.js";
import { consolePrinter } from "/vendor/ruby-wasm-wasi/console.js";
import { Directory, File, OpenFile, PreopenDirectory, WASI } from "/vendor/wasi/index.js";
import { createWorkspaceController } from "/workspace.js";
import { loadApplication, fetchJson, fetchRequired, validateRuntimeConfig, verifyBytes, hydrateFilesystem, escapeHtml } from "/loader.js";

async function boot() {
  const element = document.querySelector("#boot");
  try {
    const config = validateRuntimeConfig(await fetchJson("/runtime-config.json", "runtime configuration", {cache:"no-store"}));
    const [application, response] = await Promise.all([
      loadApplication(config),
      fetchRequired(config.runtime.url, "pinned Ruby WASM", {cache:"force-cache",integrity:config.runtime.integrity})
    ]);
    const bytes = new Uint8Array(await response.arrayBuffer());
    await verifyBytes(bytes, config.runtime, "Ruby WASM runtime");
    const module = await WebAssembly.compile(bytes);
    const root = hydrateFilesystem(application.files);
    const fds = [
      new OpenFile(new File([])), new OpenFile(new File([])),
      new OpenFile(new File([])), new PreopenDirectory("/", root.contents)
    ];
    const wasi = new WASI([], [], fds, {debug:false});
    const printer = consolePrinter();
    const {vm} = await RubyVM.instantiateModule({
      module, wasip1:wasi,
      addToImports: imports => printer.addToImports(imports),
      setMemory: memory => printer.setMemory(memory)
    });
    const workspaceConfig = await fetchJson("/workspace-config.json", "workspace configuration", {cache:"no-store"});
    const workspace = createWorkspaceController(workspaceConfig);
    await workspace.initialize();
    window.DieslWorkspace = workspace;
    const loadPaths = application.manifest.filesystem.load_paths.map(JSON.stringify).join(",");
    vm.eval(`$LOAD_PATH.unshift(${loadPaths}); require "boot"`);
    element.remove();
    workspace.attach();
    window.DieslDiagnostics = {ruby:config.runtime.ruby_version, vmCount:1, loaded:true};
  } catch (error) {
    element.innerHTML = `<h2>Diesl WASM boot failed</h2><pre class="error">${escapeHtml(error.stack || String(error))}</pre>`;
    window.DieslDiagnostics = {loaded:false,error:String(error)};
    console.error(error);
  }
}
boot();
