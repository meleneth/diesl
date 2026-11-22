// Domain-neutral browser Git history and revision restoration for Diesl.
// The caller supplies project-specific phases and semantic checkout validation.
import { createGitCapability } from "./git-capability.js";

export function validateWorkspacePath(value) {
  if (typeof value !== "string" || !value || value.startsWith("/") ||
      value.includes("\\") || value.includes("\0") ||
      value.split("/").some(part => !part || part === "." || part === ".." || part === ".git"))
    throw new Error(`Unsafe workspace path: ${String(value)}`);
  return value;
}

export function createWorkspaceHistory({
  fs, pfs = fs.promises, git, author, root,
  generatedRepository = "/generated-project", generatedMirror = "generate"
}) {
  if (!root?.startsWith("/") || !generatedRepository?.startsWith("/"))
    throw new Error("Workspace roots must be absolute");
  validateWorkspacePath(generatedMirror);
  const gitCapability = createGitCapability({fs, pfs, git, author});
  const staged = generatedRepository + "-next";
  const backup = generatedRepository + "-previous";
  const mirror = root + "/" + generatedMirror;
  const mirrorStaged = root + "/.diesl/generated-next";
  const mirrorBackup = root + "/.diesl/generated-previous";
  let ready = false;

  const exists = async path => {
    try { await pfs.stat(path); return true; }
    catch (error) { if (error.code === "ENOENT") return false; throw error; }
  };
  async function mkdirp(path) {
    if (path === "/" || !path) return;
    if (await exists(path)) return;
    await mkdirp(path.slice(0, path.lastIndexOf("/")) || "/");
    try { await pfs.mkdir(path); }
    catch (error) { if (error.code !== "EEXIST") throw error; }
  }
  async function removeTree(path) {
    if (!await exists(path)) return;
    if ((await pfs.stat(path)).isDirectory()) {
      for (const child of await pfs.readdir(path)) await removeTree(path + "/" + child);
      await pfs.rmdir(path);
    } else await pfs.unlink(path);
  }
  async function renameInto(from, target, previous) {
    await removeTree(previous);
    const hadOld = await exists(target);
    if (hadOld) await pfs.rename(target, previous);
    try { await pfs.rename(from, target); }
    catch (error) {
      if (hadOld) await pfs.rename(previous, target);
      throw error;
    }
    return hadOld;
  }
  async function writeTree(destination, entries) {
    await removeTree(destination);
    await mkdirp(destination);
    for (const [path, bytes] of [...entries].sort(([a], [b]) => a.localeCompare(b))) {
      validateWorkspacePath(path);
      const target = destination + "/" + path;
      await mkdirp(target.slice(0, target.lastIndexOf("/")));
      await pfs.writeFile(target, bytes);
    }
  }
  async function flush() {
    if (typeof pfs.flush === "function") await pfs.flush();
  }
  const decode = value => {
    if (typeof value !== "string") throw new Error("Generated file bytes must be Base64");
    return Uint8Array.from(atob(value), character => character.charCodeAt(0));
  };
  const encode = bytes => {
    let binary = "";
    for (let i = 0; i < bytes.length; i += 32768)
      binary += String.fromCharCode(...bytes.subarray(i, i + 32768));
    return btoa(binary);
  };

  return {
    get ready() { return ready; },
    async publish(steps) {
      ready = false;
      if (!Array.isArray(steps) || steps.length < 2)
        throw new Error("Generation history must contain multiple committed phases");
      const finalFiles = new Map();
      await removeTree(staged);
      await mkdirp(staged);
      try {
        await gitCapability.initialize(staged);
        for (const [index, step] of steps.entries()) {
          if (!step || typeof step.message !== "string" || !step.message.trim() ||
              !step.writes || Array.isArray(step.writes) || typeof step.writes !== "object" ||
              !Array.isArray(step.deletes)) throw new Error(`Invalid generation phase ${index}`);
          const writes = Object.fromEntries(Object.entries(step.writes).map(([name, encoded]) =>
            [validateWorkspacePath(name), decode(encoded)]));
          for (const name of step.deletes) validateWorkspacePath(name);
          await gitCapability.checkpoint(staged, {message: step.message, writes, deletes: step.deletes});
          for (const name of step.deletes) finalFiles.delete(name);
          for (const [name, bytes] of Object.entries(writes)) finalFiles.set(name, bytes);
        }
        // Prepare both trees before touching either published destination.
        await writeTree(mirrorStaged, finalFiles);
        const hadGenerated = await renameInto(staged, generatedRepository, backup);
        try {
          await renameInto(mirrorStaged, mirror, mirrorBackup);
        } catch (error) {
          await removeTree(generatedRepository);
          if (hadGenerated) await pfs.rename(backup, generatedRepository);
          throw error;
        }
        await removeTree(backup);
        await removeTree(mirrorBackup);
        await flush();
        ready = true;
        return {commits: steps.length, files: finalFiles.size};
      } catch (error) {
        await removeTree(staged);
        await removeTree(mirrorStaged);
        throw error;
      }
    },
    async exportGenerated() {
      if (!ready) throw new Error("Generated Git history is not ready for export");
      const log = await gitCapability.log(generatedRepository);
      if (log.length < 2) throw new Error("Generated project lacks incremental Git history");
      const entries = {};
      async function collect(directory, prefix = "") {
        for (const name of (await pfs.readdir(directory)).sort()) {
          const absolute = directory + "/" + name;
          const relative = prefix ? prefix + "/" + name : name;
          if ((await pfs.stat(absolute)).isDirectory()) await collect(absolute, relative);
          else entries[relative] = encode(new Uint8Array(await pfs.readFile(absolute)));
        }
      }
      await flush();
      await collect(generatedRepository);
      if (!entries[".git/HEAD"]) throw new Error("Generated Git metadata missing");
      return entries;
    }
  };
}

export function createWorkspaceRevision({fs, pfs = fs.promises, git, root, sourcePath, lastValidPath}) {
  validateWorkspacePath(sourcePath);
  validateWorkspacePath(lastValidPath);
  if (!root.startsWith("/")) throw new Error("Workspace root must be absolute");
  return {
    async restore(oid, {guard = () => {}, validate}) {
      if (typeof validate !== "function") throw new Error("Revision restore requires domain validation");
      const matrix = await git.statusMatrix({fs, dir: root});
      if (matrix.some(([, head, worktree, stage]) => !(head === 1 && worktree === 1 && stage === 1)))
        throw new Error("Commit or discard working-tree changes before restoring a revision.");
      await guard();
      const previous = await git.resolveRef({fs, dir: root, ref: "HEAD"});
      await git.checkout({fs, dir: root, ref: oid, noUpdateHead: true, force: true, nonBlocking: true});
      try {
        const bytes = await pfs.readFile(root + "/" + sourcePath);
        const source = new TextDecoder("utf-8", {fatal: true}).decode(bytes);
        if (!source) throw new Error("The selected revision has empty source");
        await validate(source);
        const target = root + "/" + lastValidPath;
        const directory = target.slice(0, target.lastIndexOf("/"));
        // Existing managed last-valid snapshot normally has this directory.
        if (directory) {
          const parts = directory.split("/").filter(Boolean);
          let current = "";
          for (const part of parts) {
            current += "/" + part;
            try { await pfs.mkdir(current); }
            catch (error) { if (error.code !== "EEXIST") throw error; }
          }
        }
        await pfs.writeFile(target, bytes);
      } catch (error) {
        await git.checkout({fs, dir: root, ref: previous, noUpdateHead: true, force: true, nonBlocking: true});
        throw new Error(`Checkout was rolled back: ${error.message || String(error)}`);
      }
      if (typeof pfs.flush === "function") await pfs.flush();
    }
  };
}
