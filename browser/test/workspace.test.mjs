import test from "node:test";
import assert from "node:assert/strict";
import { createWorkspaceController, validateWorkspaceManifest } from "../public/workspace.js";

const manifest = () => ({
  version: 1, root: "/workspace", storage: "browser",
  source: {path: "fleet.rb", last_valid: ".diesl/last-valid.rb"},
  git: {branch: "main", author: {name: "Diesl", email: "test@example.invalid"}},
  generated: [{path: "generate"}], embedded: []
});

class FakeFS {
  constructor() {
    this.nodes = new Map([["/", null]]);
    this.promises = {
      stat: async path => {
        if (!this.nodes.has(path)) throw Object.assign(new Error("not found"), {code: "ENOENT"});
        return {isDirectory: () => this.nodes.get(path) === null};
      },
      mkdir: async path => {this.nodes.set(path, null);},
      readFile: async path => {
        if (!this.nodes.has(path)) throw Object.assign(new Error("not found"), {code: "ENOENT"});
        return this.nodes.get(path);
      },
      writeFile: async (path, data) => {this.nodes.set(path, data);},
      readdir: async path => [...this.nodes.keys()].filter(k => k.startsWith(path + "/") &&
        !k.slice(path.length + 1).includes("/")).map(k => k.slice(path.length + 1)),
      rmdir: async path => {this.nodes.delete(path);},
      unlink: async path => {this.nodes.delete(path);},
      rename: async (from, to) => {
        for (const [path, value] of [...this.nodes]) {
          if (path === from || path.startsWith(from + "/")) {
            this.nodes.delete(path);
            this.nodes.set(to + path.slice(from.length), value);
          }
        }
      }
    };
  }
  async flush() {}
}

function stub() {
  const filesystem = new FakeFS();
  const history = [];
  const git = {
    init: async () => {filesystem.nodes.set("/workspace/.git", null);},
    resolveRef: async () => {if (!history.length) throw new Error("Could not resolve HEAD"); return "abcd";},
    add: async () => {},
    commit: async options => {history.push(options.message);},
    statusMatrix: async () => [],
    log: async () => history.map((message, index) => ({
      oid: String(index).padStart(40, "0"), commit: {message}
    }))
  };
  const elements = new Map();
  const documentRef = {
    getElementById: id => elements.get(id) || null,
    createElement: () => ({textContent: ""})
  };
  const make = () => createWorkspaceController(manifest(), {
    FileSystem: class {constructor() {return filesystem;}}, git, documentRef
  });
  return {filesystem, history, make};
}

test("workspace policy rejects source traversal and generated overlap", () => {
  const bad = manifest(); bad.source.path = "../secrets";
  assert.throws(() => validateWorkspaceManifest(bad), /Unsafe/);
  const overlap = manifest(); overlap.generated = [{path: ".diesl"}];
  assert.throws(() => validateWorkspaceManifest(overlap), /Overlapping/);
});

test("valid and invalid drafts persist independently from last valid source", async () => {
  const {filesystem, history, make} = stub();
  const first = make();
  await first.initialize();
  assert.equal(first.hasBootstrapSource, false);
  await first.persistSource("ship 'Rocinante', crew: 4", true);
  await first.persistSource("ship 'Rocinante', crew:", false);
  const second = make();
  await second.initialize();
  assert.equal(second.bootstrapSource, "ship 'Rocinante', crew:");
  assert.equal(second.bootstrapValidSource, "ship 'Rocinante', crew: 4");
  assert.equal(history.length, 1);
  assert.ok(filesystem.nodes.has("/workspace/.git"));
});

test("only declared generated roots can be persisted", async () => {
  const {filesystem, make} = stub();
  const workspace = make();
  await workspace.initialize();
  await assert.rejects(workspace.persistGenerated("other", "{}"), /Undeclared/);
  await workspace.persistGenerated("generate", JSON.stringify({"hello.txt": btoa("hello")}));
  assert.equal(new TextDecoder().decode(filesystem.nodes.get("/workspace/generate/hello.txt")), "hello");
  await workspace.persistGenerated("generate", JSON.stringify({"next.txt": btoa("next")}));
  assert.equal(filesystem.nodes.has("/workspace/generate/hello.txt"), false);
});

test("replaying persisted initial content does not create extra commits", async () => {
  const {history, make} = stub();
  const workspace = make();
  await workspace.initialize();
  await workspace.persistSource("fleet do\nend\n", true);
  await workspace.persistSource("fleet do\nend\n", true);
  assert.equal(history.length, 1);
});
