import test from "node:test";
import assert from "node:assert/strict";
import LightningFS from "@isomorphic-git/lightning-fs";
import git from "isomorphic-git";
import { createWorkspaceController } from "../public/workspace.js";

const { MemoryBackend } = LightningFS;
if (typeof MemoryBackend !== "function") throw new Error("Pinned LightningFS lacks MemoryBackend");

async function runCase(stage, sourcePath, expected) {
  const manifest = {
    version: 1, root: "/workspace", storage: "browser",
    source: {path: sourcePath, last_valid: ".diesl/last-valid.rb"},
    generated: [{path: "generate"}], embedded: [],
    git: {branch: "main", stage, author: {name: "Diesl", email: "test@example.invalid"}}
  };
  const backend = new MemoryBackend();
  let filesystem;
  const FS = class {
    constructor(name) {
      filesystem = new LightningFS(name, {db: backend});
      return filesystem;
    }
  };
  const workspace = createWorkspaceController(manifest, {
    FileSystem: FS, git, documentRef: {getElementById: () => null}
  });
  await workspace.initialize();
  await workspace.persistSource("fleet do\nend\n", true);
  await workspace.persistGenerated("generate", JSON.stringify({
    "compose.yaml": btoa("services: {}\n")
  }));
  await workspace.stage();
  const matrix = await git.statusMatrix({fs: filesystem, dir: "/workspace"});
  const staged = matrix.filter(([,head,,index]) => head !== index).map(([path]) => path);
  assert.deepEqual(staged, expected);
  await workspace.commit("Record declared artifacts");
  const log = await git.log({fs: filesystem, dir: "/workspace", depth: 1});
  assert.equal(log[0].commit.message.trim(), "Record declared artifacts");
}

test("real isomorphic-git stages source-only workspace", async () => {
  await runCase(["source"], "fleet.rb", ["fleet.rb"]);
});

test("real isomorphic-git stages generated-only workspace", async () => {
  await runCase(["generated"], "mobilis.rb", ["generate/compose.yaml"]);
});
