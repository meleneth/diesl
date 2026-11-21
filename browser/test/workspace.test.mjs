import test from "node:test";
import assert from "node:assert/strict";
import { createWorkspaceController, validateWorkspaceManifest } from "../public/workspace.js";

const manifest = () => ({
  version: 1, root: "/workspace", storage: "browser",
  source: {path: "fleet.rb", last_valid: ".diesl/last-valid.rb"},
  git: {branch: "main", author: {name: "Diesl", email: "test@example.invalid"}, stage: ["source"]},
  generated: [{path: "generate"}], embedded: []
});

class FakeFS {
  constructor() {
    this.flushes = 0;
    this.nodes = new Map([["/", null]]);
    this.promises = {
      flush: async () => {this.flushes += 1;},
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
  flush() { throw new Error("Callback-based fs.flush must never be called"); }
}

function stub() {
  const filesystem = new FakeFS();
  const history = [];
  const added = [];
  let matrix = [];
  const git = {
    init: async () => {filesystem.nodes.set("/workspace/.git", null);},
    resolveRef: async () => {if (!history.length) throw Object.assign(new Error("Could not find refs/heads/main."), {code: "NotFoundError"}); return "abcd";},
    listFiles: async () => added,
    add: async ({filepath}) => {added.push(filepath);},
    commit: async options => {history.push(options.message);},
    statusMatrix: async () => matrix,
    log: async () => history.map((message, index) => ({
      oid: String(index).padStart(40, "0"), commit: {message}
    }))
  };
  const elements = new Map();
  const documentRef = {
    getElementById: id => elements.get(id) || null,
    createElement: () => ({textContent: ""})
  };
  const make = (policy = manifest()) => createWorkspaceController(policy, {
    FileSystem: class {constructor() {return filesystem;}}, git, documentRef
  });
  return {filesystem, history, added, make, setMatrix: rows => {matrix = rows; history.push("fixture baseline");}};
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
  assert.equal(history.length, 0);
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

test("saving source never automatically creates a Git commit", async () => {
  const {history, make} = stub();
  const workspace = make();
  await workspace.initialize();
  await workspace.persistSource("fleet do\nend\n", true);
  await workspace.persistSource("fleet do\nend\n", true);
  assert.equal(history.length, 0);
});

test("constellation stages only the declared source file", async () => {
  const {make, added, setMatrix} = stub();
  const workspace = make();
  await workspace.initialize();
  setMatrix([["fleet.rb",1,2,1],[".gitignore",0,2,0],["generate/result.txt",0,2,0]]);
  await workspace.stage();
  assert.deepEqual(added, ["fleet.rb"]);
});

test("Mobilis-style workspace stages generated files but not its source", async () => {
  const {make, added, setMatrix, filesystem} = stub();
  const policy = manifest();
  policy.source.path = "mobilis.rb";
  policy.git.stage = ["generated"];
  const workspace = make(policy);
  await workspace.initialize();
  await filesystem.promises.mkdir("/workspace/generate");
  await filesystem.promises.writeFile("/workspace/generate/compose.yaml", new TextEncoder().encode("services: {}"));
  setMatrix([["mobilis.rb",1,2,1],["generate/compose.yaml",0,2,0]]);
  await workspace.stage();
  assert.deepEqual(added, ["generate/compose.yaml"]);
});

test("invalid staging policy fails before browser initialization", () => {
  const policy = manifest();
  policy.git.stage = ["everything"];
  const {make} = stub();
  assert.throws(() => make(policy), /staging requires explicit/);
});

test("workspace flushes via fs.promises, never the callback-only fs.flush", async () => {
  const {filesystem, make} = stub();
  const workspace = make();
  await workspace.initialize();
  await workspace.persistSource("fleet do\nend\n", true);
  assert.ok(filesystem.flushes > 0);
});

test("new repository status and staging work before the first commit", async () => {
  const {make, added, history} = stub();
  const workspace = make();
  await workspace.initialize();
  await workspace.persistSource("fleet do\nend\n", true);
  await workspace.stage();
  assert.deepEqual(added, ["fleet.rb"]);
  assert.equal(history.length, 0);
});
