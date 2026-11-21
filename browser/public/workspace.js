// Browser persistence adapter for Diesl::Workspace. No DSL semantics here.
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

function pathCheck(path) {
  if (typeof path !== "string" || !path || path.startsWith("/") ||
      path.includes("\\") || path.includes("\0") ||
      path.split("/").some(p => !p || p === "." || p === ".."))
    throw new Error("Unsafe workspace path: " + String(path));
  return path;
}

export function validateWorkspaceManifest(m) {
  if (!m || m.version !== 1 || m.storage !== "browser" ||
      typeof m.root !== "string" || !m.root.startsWith("/") ||
      m.root.split("/").slice(1).some(p => !p || p === "." || p === "..") ||
      !m.source || !Array.isArray(m.generated) || !Array.isArray(m.embedded))
    throw new Error("Invalid Diesl workspace manifest");
  pathCheck(m.source.path);
  pathCheck(m.source.last_valid);
  if (m.source.path === m.source.last_valid) throw new Error("Overlapping source paths");
  const reserved = [m.source.path, m.source.last_valid, ".git", ".gitignore"];
  const generated = [];
  for (const entry of m.generated) {
    pathCheck(entry.path);
    if (reserved.some(path => path === entry.path || path.startsWith(entry.path + "/") ||
        entry.path.startsWith(path + "/")) ||
        generated.some(path => path === entry.path || path.startsWith(entry.path + "/") ||
          entry.path.startsWith(path + "/")))
      throw new Error("Overlapping generated workspace path");
    generated.push(entry.path);
  }
  if (m.git && (!m.git.author || !m.git.author.name || !m.git.author.email ||
      !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(m.git.branch) ||
      m.git.branch.includes("..") || m.git.branch.includes("//") ||
      m.git.branch.endsWith(".lock")))
    throw new Error("Invalid workspace Git policy");
  return m;
}

export function createWorkspaceController(manifest, { FileSystem = window.LightningFS, git = window.git, documentRef = document } = {}) {
  const policy = validateWorkspaceManifest(manifest);
  const fs = new FileSystem("diesl-v1-" + policy.source.path.replaceAll("/", "_"));
  const pfs = fs.promises;
  const dir = policy.root;
  const stageKinds = policy.git?.stage;
  if (policy.git && (!Array.isArray(stageKinds) || stageKinds.length === 0 ||
      stageKinds.some(kind => !["source", "generated"].includes(kind))))
    throw new Error("Git staging requires explicit source/generated selection");
  const stageRoots = () => [
    ...(stageKinds?.includes("source") ? [policy.source.path] : []),
    ...(stageKinds?.includes("generated") ? policy.generated.map(item => item.path) : [])
  ];
  const allowed = path => stageRoots().some(root =>
    path === root || (stageKinds.includes("generated") &&
      policy.generated.some(item => item.path === root) && path.startsWith(root + "/")));

  const internalSnapshot = policy.source.last_valid;
  const ignoreRule = internalSnapshot.includes("/")
    ? internalSnapshot.slice(0, internalSnapshot.lastIndexOf("/") + 1)
    : internalSnapshot;
  let initialized = false, attached = false;
  let queue = Promise.resolve();
  const absolute = path => dir + "/" + pathCheck(path);

  async function exists(path) {
    try { await pfs.stat(path); return true; }
    catch (e) { if (e.code === "ENOENT") return false; throw e; }
  }
  async function mkdirp(path) {
    let current = "";
    for (const part of path.split("/").filter(Boolean)) {
      current += "/" + part;
      if (!await exists(current)) {
        try { await pfs.mkdir(current); }
        catch (e) { if (e.code !== "EEXIST") throw e; }
      }
    }
  }
  async function read(path) {
    try { return decoder.decode(await pfs.readFile(absolute(path))); }
    catch (e) { if (e.code === "ENOENT") return null; throw e; }
  }
  async function write(path, text) {
    const target = absolute(path);
    await mkdirp(target.slice(0, target.lastIndexOf("/")));
    if (await read(path) !== text) await pfs.writeFile(target, encoder.encode(text));
  }
  async function flush() { if (typeof fs.flush === "function") await fs.flush(); }
  function errorStatus(e) {
    const node = documentRef.getElementById("workspace-status");
    if (node) { node.className = "error"; node.textContent = "Workspace error: " + (e.message || String(e)); }
  }
  function enqueue(operation) {
    const work = queue.then(operation);
    queue = work.catch(errorStatus);
    return work;
  }
  async function commitInitialSource() {
    if (!policy.git) return;
    try { await git.resolveRef({fs, dir, ref: "HEAD"}); return; }
    catch (e) { if (!/not found|Could not resolve|unknown ref|ENOENT/i.test(String(e.message))) throw e; }
    if (stageKinds.includes("source")) {
      await git.add({fs, dir, filepath: policy.source.path});
      await git.commit({fs, dir, message: "Initialize Diesl workspace", author: policy.git.author});
    }
  }
  async function refreshView() {
    if (!attached || !policy.git) return;
    const matrix = await git.statusMatrix({fs, dir});
    const dirty = matrix.filter(([,head,worktree,stage]) => !(head === 1 && worktree === 1 && stage === 1));
    const status = documentRef.getElementById("workspace-status");
    if (status) { status.className = "muted"; status.textContent = dirty.length ? dirty.length + " changed workspace files" : "Git working tree clean"; }
    const history = documentRef.getElementById("workspace-history");
    if (!history) return;
    const log = await git.log({fs, dir, depth: 10}).catch(e => {
      if (/not found|unknown ref/i.test(String(e.message))) return [];
      throw e;
    });
    history.replaceChildren();
    for (const item of log) {
      const li = documentRef.createElement("li");
      li.textContent = item.oid.slice(0, 8) + " " + item.commit.message.trim();
      history.append(li);
    }
  }
  const api = {
    bootstrapSource: "",
    bootstrapValidSource: "",
    hasBootstrapSource: false,
    async initialize() {
      if (initialized) return;
      await mkdirp(dir);
      await mkdirp(absolute(policy.source.last_valid).replace(/\/[^/]+$/, ""));
      if (policy.git && !await exists(dir + "/.git"))
        await git.init({fs, dir, defaultBranch: policy.git.branch});
      const source = await read(policy.source.path);
      api.bootstrapSource = source ?? "";
      api.hasBootstrapSource = source !== null;
      api.bootstrapValidSource = await read(policy.source.last_valid) ?? "";
      initialized = true;
    },
    persistSource(source, valid) {
      return enqueue(async () => {
        if (!initialized) throw new Error("Workspace not initialized");
        await write(policy.source.path, String(source));
        if (valid) await write(policy.source.last_valid, String(source));
        if (policy.git) {
          const existingIgnore = await read(".gitignore");
          const rule = "/" + ignoreRule;
          if (!existingIgnore || !existingIgnore.split("\n").includes(rule)) {
            await write(".gitignore", (existingIgnore || "") + 
              (existingIgnore && !existingIgnore.endsWith("\n") ? "\n" : "") + rule + "\n");
          }
        }
        await commitInitialSource();
        await flush();
        await refreshView();
      });
    },
    // Generated content is committed atomically to a declared subtree.
    // Values are Base64 strings so binary files remain byte-exact.
    persistGenerated(root, serialized) {
      return enqueue(async () => {
        if (!policy.generated.some(item => item.path === root))
          throw new Error("Undeclared generated root");
        const files = JSON.parse(serialized);
        if (!files || Array.isArray(files) || typeof files !== "object")
          throw new Error("Generated files must be a path-to-Base64 object");
        for (const path of Object.keys(files)) pathCheck(path);
        const next = root + "-next", previous = root + "-previous";
        const remove = async path => {
          if (!await exists(path)) return;
          const stat = await pfs.stat(path);
          if (stat.isDirectory()) {
            for (const child of await pfs.readdir(path)) await remove(path + "/" + child);
            await pfs.rmdir(path);
          } else await pfs.unlink(path);
        };
        // Temporary paths must not conflict with declared or reserved roots.
        for (const candidate of [next, previous]) {
          if ([policy.source.path, policy.source.last_valid, ".git", ".gitignore",
            ...policy.generated.map(item => item.path)].some(path =>
              path === candidate || path.startsWith(candidate + "/") ||
              candidate.startsWith(path + "/")))
            throw new Error("Generated staging path conflicts with workspace");
        }
        await remove(absolute(next));
        await remove(absolute(previous));
        await mkdirp(absolute(next));
        for (const [path, encoded] of Object.entries(files)) {
          if (typeof encoded !== "string") throw new Error("Generated content must be Base64");
          const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
          const target = absolute(next + "/" + path);
          await mkdirp(target.slice(0, target.lastIndexOf("/")));
          await pfs.writeFile(target, bytes);
        }
        const hadOld = await exists(absolute(root));
        if (hadOld) await pfs.rename(absolute(root), absolute(previous));
        try { await pfs.rename(absolute(next), absolute(root)); }
        catch (error) {
          if (hadOld) await pfs.rename(absolute(previous), absolute(root));
          throw error;
        }
        await remove(absolute(previous));
        await flush();
        await refreshView();
      });
    },
    stage() {
      return enqueue(async () => {
        if (!policy.git) throw new Error("Git not enabled");
        const matrix = await git.statusMatrix({fs, dir});
        for (const [path,,worktree] of matrix) {
          if (worktree === 0) await git.remove({fs, dir, filepath: path});
          else await git.add({fs, dir, filepath: path});
        }
        await flush(); await refreshView();
      });
    },
    commit(message) {
      return enqueue(async () => {
        if (!policy.git) throw new Error("Git not enabled");
        if (!message.trim()) throw new Error("Commit message required");
        const matrix = await git.statusMatrix({fs, dir});
        if (!matrix.some(([,head,,stage]) => head !== stage)) throw new Error("Nothing staged");
        await git.commit({fs, dir, message: message.trim(), author: policy.git.author});
        await flush(); await refreshView();
      });
    },
    attach() {
      if (attached) return;
      attached = true;
      documentRef.getElementById("workspace-stage")?.addEventListener("click", () => { api.stage().catch(errorStatus); });
      documentRef.getElementById("workspace-commit")?.addEventListener("click", () => {
        const field = documentRef.getElementById("workspace-message");
        api.commit(field?.value || "").then(() => { if (field) field.value = ""; }).catch(errorStatus);
      });
      enqueue(refreshView).catch(errorStatus);
    }
  };
  return api;
}
