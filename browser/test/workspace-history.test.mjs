import test from "node:test";
import assert from "node:assert/strict";
import {createWorkspaceHistory, createWorkspaceRevision} from "../public/workspace-history.js";

class MemoryFS {
  constructor() {
    this.nodes = new Map([["/", null], ["/workspace", null], ["/workspace/.diesl", null]]);
    this.promises = {
      flush: async () => {},
      stat: async path => {
        const value = this.lookup(path);
        return {isDirectory: () => value === null};
      },
      mkdir: async path => {
        if (this.nodes.has(path)) throw Object.assign(new Error("exists"), {code: "EEXIST"});
        const parent = path.slice(0, path.lastIndexOf("/")) || "/";
        if (this.lookup(parent) !== null) throw new Error("parent not directory");
        this.nodes.set(path, null);
      },
      readFile: async path => {
        const value = this.lookup(path);
        if (!(value instanceof Uint8Array)) throw new Error("not a file");
        return value;
      },
      writeFile: async (path, bytes) => {
        const parent = path.slice(0, path.lastIndexOf("/")) || "/";
        if (this.lookup(parent) !== null) throw new Error("parent not directory");
        this.nodes.set(path, new Uint8Array(bytes));
      },
      readdir: async path => {
        if (this.lookup(path) !== null) throw new Error("not a directory");
        return [...this.nodes.keys()].filter(name => name.startsWith(path + "/") &&
          !name.slice(path.length + 1).includes("/")).map(name => name.slice(path.length + 1));
      },
      unlink: async path => { this.lookup(path); this.nodes.delete(path); },
      rmdir: async path => {
        this.lookup(path);
        if ([...this.nodes.keys()].some(name => name.startsWith(path + "/")))
          throw new Error("directory not empty");
        this.nodes.delete(path);
      },
      rename: async (from, to) => {
        this.lookup(from);
        if (this.nodes.has(to)) throw new Error("destination exists");
        for (const [key, value] of [...this.nodes]) {
          if (key === from || key.startsWith(from + "/")) {
            this.nodes.delete(key);
            this.nodes.set(to + key.slice(from.length), value);
          }
        }
      }
    };
  }
  lookup(path) {
    if (!this.nodes.has(path)) throw Object.assign(new Error("missing " + path), {code: "ENOENT"});
    return this.nodes.get(path);
  }
  text(path) { return new TextDecoder().decode(this.lookup(path)); }
}

function makeGit(fs) {
  const repositories = new Map();
  const tracked = new Map();
  const repo = dir => {
    if (!repositories.has(dir)) repositories.set(dir, []);
    if (!tracked.has(dir)) tracked.set(dir, new Set());
    return repositories.get(dir);
  };
  return {
    repositories,
    async init({dir}) {
      if (!fs.nodes.has(dir)) fs.nodes.set(dir, null);
      fs.nodes.set(dir + "/.git", null);
      fs.nodes.set(dir + "/.git/HEAD", new TextEncoder().encode("ref: refs/heads/main\n"));
      repositories.set(dir, []);
      tracked.set(dir, new Set());
    },
    async isIgnored() { return false; },
    async add({dir, filepath}) { repo(dir); tracked.get(dir).add(filepath); },
    async remove({dir, filepath}) { repo(dir); tracked.get(dir).delete(filepath); },
    async resolveRef({dir}) {
      const revisions = repo(dir);
      if (!revisions.length)
        throw Object.assign(new Error("Could not find refs/heads/main"), {code: "NotFoundError"});
      return revisions[revisions.length - 1].oid;
    },
    async statusMatrix({dir}) {
      const revisions = repo(dir);
      const head = revisions[revisions.length - 1];
      return [...tracked.get(dir)].map(filepath => {
        const previous = head?.files?.get(filepath);
        const current = fs.lookup(dir + "/" + filepath);
        const unchanged = previous && previous.length === current.length &&
          previous.every((byte, index) => byte === current[index]);
        return [filepath, previous ? 1 : 0, unchanged ? 1 : 2, unchanged ? 1 : 2];
      });
    },
    async commit({dir, message}) {
      const revisions = repo(dir);
      const entries = new Map();
      for (const filepath of tracked.get(dir)) entries.set(filepath, new Uint8Array(fs.lookup(dir + "/" + filepath)));
      const oid = String(revisions.length + 1).padStart(40, "0");
      revisions.push({oid, message, files: entries});
      return oid;
    },
    async log({dir}) {
      const revisions = repositories.get(dir) || repositories.get(dir + "-next") || repo(dir);
      return [...revisions].reverse().map(item => ({oid: item.oid, commit: {message: item.message}}));
    },
    async checkout({dir, ref}) {
      const revision = repo(dir).find(item => item.oid === ref);
      if (!revision) throw new Error("revision not found");
      for (const [path, bytes] of revision.files)
        fs.nodes.set(dir + "/" + path, bytes);
    }
  };
}

const author = {name: "Diesl", email: "test@example.invalid"};
const encode = text => btoa(text);
const phase = (message, writes, deletes = []) => ({
  message, writes: Object.fromEntries(Object.entries(writes).map(([key, value]) => [key, encode(value)])),
  deletes
});

test("preserves independent generated commits and exports Git objects byte-exact", async () => {
  const fs = new MemoryFS();
  const git = makeGit(fs);
  const history = createWorkspaceHistory({fs, git, author, root: "/workspace"});
  const result = await history.publish([
    phase("[mobilis] initial", {"one.txt": "one"}),
    phase("[mobilis] next", {"two.txt": "two"})
  ]);
  assert.deepEqual(result, {commits: 2, files: 2});
  assert.equal(history.ready, true);
  assert.equal(fs.text("/workspace/generate/one.txt"), "one");
  assert.equal(fs.text("/generated-project/two.txt"), "two");
  assert.equal(git.repositories.get("/generated-project-next").length, 2);
  const exported = await history.exportGenerated();
  assert.equal(atob(exported["two.txt"]), "two");
  assert.ok(exported[".git/HEAD"]);
});

test("bad second phase does not replace previous generated project or mirrored artifacts", async () => {
  const fs = new MemoryFS();
  const git = makeGit(fs);
  const history = createWorkspaceHistory({fs, git, author, root: "/workspace"});
  await history.publish([phase("first", {"keep.txt": "old"}), phase("second", {"other.txt": "old2"})]);
  await assert.rejects(history.publish([
    phase("new", {"replace.txt": "new"}),
    phase("bad", {"../outside": "unsafe"})
  ]), /Unsafe/);
  assert.equal(fs.text("/generated-project/keep.txt"), "old");
  assert.equal(fs.text("/workspace/generate/keep.txt"), "old");
  assert.equal(history.ready, false);
});

test("mirror publish failure restores both the previous generated repository and working tree", async () => {
  const fs = new MemoryFS();
  const git = makeGit(fs);
  const history = createWorkspaceHistory({fs, git, author, root: "/workspace"});
  await history.publish([phase("initial", {"keep.txt": "original"}), phase("phase2", {"other.txt": "present"})]);
  const rename = fs.promises.rename;
  let injected = false;
  fs.promises.rename = async (from, to) => {
    if (from === "/workspace/.diesl/generated-next" && to === "/workspace/generate" && !injected) {
      injected = true;
      throw new Error("simulated mirror rename failure");
    }
    return rename(from, to);
  };
  await assert.rejects(history.publish([
    phase("replacement", {"replace.txt": "new"}),
    phase("more", {"last.txt": "newer"})
  ]), /simulated mirror rename failure/);
  assert.equal(fs.text("/generated-project/keep.txt"), "original");
  assert.equal(fs.text("/workspace/generate/keep.txt"), "original");
  assert.equal(fs.nodes.has("/generated-project/replace.txt"), false);
  assert.equal(fs.nodes.has("/workspace/generate/replace.txt"), false);
});

test("failed last-valid snapshot writes roll back both the Git source and saved snapshot", async () => {
  const fs = new MemoryFS();
  const git = makeGit(fs);
  await git.init({dir: "/workspace"});
  fs.nodes.set("/workspace/mobilis.rb", new TextEncoder().encode("older"));
  await git.add({dir: "/workspace", filepath: "mobilis.rb"});
  const target = await git.commit({dir: "/workspace", message: "older"});
  fs.nodes.set("/workspace/mobilis.rb", new TextEncoder().encode("current"));
  await git.commit({dir: "/workspace", message: "current"});
  fs.nodes.set("/workspace/.diesl/last-valid.rb", new TextEncoder().encode("last known good"));
  const writeFile = fs.promises.writeFile;
  let failed = false;
  fs.promises.writeFile = async (path, bytes) => {
    if (path === "/workspace/.diesl/last-valid.rb" && !failed) {
      failed = true;
      throw new Error("simulated snapshot write failure");
    }
    return writeFile(path, bytes);
  };
  const revision = createWorkspaceRevision({fs, git, root: "/workspace",
    sourcePath: "mobilis.rb", lastValidPath: ".diesl/last-valid.rb"});
  await assert.rejects(revision.restore(target, {validate: () => {}}), /rolled back: simulated snapshot write failure/);
  assert.equal(fs.text("/workspace/mobilis.rb"), "current");
  assert.equal(fs.text("/workspace/.diesl/last-valid.rb"), "last known good");
});

test("restoration rejects dirty trees and rolls back rejected domain source", async () => {
  const fs = new MemoryFS();
  const git = makeGit(fs);
  await git.init({dir: "/workspace"});
  fs.nodes.set("/workspace/mobilis.rb", new TextEncoder().encode("old"));
  await git.add({dir: "/workspace", filepath: "mobilis.rb"});
  const earlier = await git.commit({dir: "/workspace", message: "initial"});
  fs.nodes.set("/workspace/mobilis.rb", new TextEncoder().encode("current"));
  await git.commit({dir: "/workspace", message: "current"});
  const revision = createWorkspaceRevision({fs, git, root: "/workspace",
    sourcePath: "mobilis.rb", lastValidPath: ".diesl/last-valid.rb"});
  await assert.rejects(revision.restore(earlier, {validate: () => {
    throw new Error("domain invalid");
  }}), /rolled back: domain invalid/);
  assert.equal(fs.text("/workspace/mobilis.rb"), "current");
  await revision.restore(earlier, {validate: source => {
    assert.equal(source, "old");
  }});
  assert.equal(fs.text("/workspace/mobilis.rb"), "old");
  assert.equal(fs.text("/workspace/.diesl/last-valid.rb"), "old");
  const badGit = {...git, statusMatrix: async () => [["mobilis.rb", 1, 2, 1]]};
  const guarded = createWorkspaceRevision({fs, git: badGit, root: "/workspace",
    sourcePath: "mobilis.rb", lastValidPath: ".diesl/last-valid.rb"});
  await assert.rejects(guarded.restore(earlier, {validate: () => {}}), /working-tree changes/);
});
