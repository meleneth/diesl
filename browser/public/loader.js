import { Directory, File } from "/vendor/wasi/index.js";

async function loadApplication(config) {
  const timings = {};
  const manifestStarted = performance.now();
  const manifest = validateApplicationManifest(
    await fetchJson(config.application_manifest_url, "Diesl application manifest", { cache: "no-store" }),
    config.runtime
  );
  timings.applicationManifestMs = elapsed(manifestStarted);

  const archiveStarted = performance.now();
  const response = await fetchRequired(manifest.artifact.url, "Diesl application archive", {
    cache: "force-cache",
    integrity: manifest.artifact.integrity
  });
  const archive = new Uint8Array(await response.arrayBuffer());
  await verifyBytes(archive, manifest.artifact, "Diesl application archive");
  timings.applicationArchiveFetchAndVerifyMs = elapsed(archiveStarted);

  const unpackStarted = performance.now();
  const files = readTar(archive);
  await validateApplicationFiles(files, manifest.filesystem.files);
  timings.applicationUnpackAndVerifyMs = elapsed(unpackStarted);
  return { manifest, files, archiveBytes: archive.byteLength, timings };
}

async function fetchJson(url, label, options) {
  const response = await fetchRequired(url, label, options);
  try {
    return await response.json();
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`, { cause: error });
  }
}

async function fetchRequired(url, label, options = {}) {
  let response;
  try {
    response = await fetch(url, options);
  } catch (error) {
    throw new Error(`Unable to load ${label} from ${url}: ${error.message}`, { cause: error });
  }
  if (!response.ok) throw new Error(`Unable to load ${label} from ${url}: HTTP ${response.status}`);
  return response;
}

function validateRuntimeConfig(config) {
  if (config?.format !== "diesl-browser-runtime" || config?.version !== 1) {
    throw new Error("Unsupported or malformed Diesl runtime configuration");
  }
  const runtime = config.runtime;
  if (!runtime || runtime.package !== "mobilis-ruby-wasm" || runtime.ruby_version !== "4.0.10") {
    throw new Error("Runtime configuration is not compatible with Diesl's pinned Ruby 4.0 WASM runtime");
  }
  validateIntegrityRecord(runtime, "Ruby WASM runtime");
  if (typeof runtime.url !== "string" || !runtime.url) throw new Error("Ruby WASM runtime URL is missing");
  if (typeof config.application_manifest_url !== "string" || !config.application_manifest_url) {
    throw new Error("Diesl application manifest URL is missing");
  }
  return config;
}

function validateApplicationManifest(manifest, runtime) {
  if (manifest?.format !== "diesl-browser-application" || manifest?.version !== 1) {
    throw new Error("Unsupported or malformed Diesl application manifest");
  }
  const compatible = manifest.compatible_runtime;
  if (compatible?.package !== runtime.package || compatible?.package_version !== runtime.package_version) {
    throw new Error(`Diesl application ${manifest.application_version || "(unknown)"} is incompatible with ${runtime.package}@${runtime.package_version}`);
  }
  validateIntegrityRecord(manifest.artifact, "Diesl application archive");
  if (typeof manifest.artifact.url !== "string" || !manifest.artifact.url) throw new Error("Diesl application archive URL is missing");
  if (!manifest.filesystem || !Array.isArray(manifest.filesystem.load_paths) || !Array.isArray(manifest.filesystem.files)) {
    throw new Error("Diesl application filesystem manifest is malformed");
  }
  if (!manifest.filesystem.load_paths.every(path => typeof path === "string" && safeAbsolutePath(path))) {
    throw new Error("Diesl application manifest contains an unsafe load path");
  }
  if (typeof manifest.filesystem.boot_feature !== "string" || !manifest.filesystem.boot_feature) {
    throw new Error("Diesl application boot feature is missing");
  }
  return manifest;
}

function validateIntegrityRecord(record, label) {
  if (!record || !Number.isSafeInteger(record.size) || record.size < 0 || !/^[a-f0-9]{64}$/.test(record.sha256 || "")) {
    throw new Error(`${label} integrity metadata is malformed`);
  }
  if (record.integrity !== `sha256-${hexToBase64(record.sha256)}`) {
    throw new Error(`${label} integrity metadata is inconsistent`);
  }
}

async function verifyBytes(bytes, record, label) {
  if (bytes.byteLength !== record.size) throw new Error(`${label} size mismatch: expected ${record.size}, received ${bytes.byteLength}`);
  const actual = await sha256Hex(bytes);
  if (actual !== record.sha256) throw new Error(`${label} integrity check failed`);
}

function readTar(archive) {
  const blockSize = 512;
  if (archive.byteLength < blockSize * 2 || archive.byteLength % blockSize !== 0) {
    throw new Error("Diesl application archive is not a complete tar stream");
  }
  const files = new Map();
  let offset = 0;
  let terminated = false;
  while (offset + blockSize <= archive.byteLength) {
    const header = archive.subarray(offset, offset + blockSize);
    offset += blockSize;
    if (allZero(header)) {
      const second = archive.subarray(offset, offset + blockSize);
      if (second.byteLength !== blockSize || !allZero(second)) throw new Error("Diesl application archive has an incomplete terminator");
      offset += blockSize;
      terminated = true;
      break;
    }
    validateTarHeader(header);
    const name = tarText(header.subarray(0, 100));
    const prefix = tarText(header.subarray(345, 500));
    const path = prefix ? `${prefix}/${name}` : name;
    if (!safeRelativePath(path)) throw new Error(`Diesl application archive contains unsafe path ${JSON.stringify(path)}`);
    if (files.has(path)) throw new Error(`Diesl application archive contains duplicate path ${path}`);
    const type = header[156];
    if (type !== 0 && type !== 48) throw new Error(`Diesl application archive contains unsupported entry type for ${path}`);
    const size = tarOctal(header.subarray(124, 136), `size for ${path}`);
    const padded = Math.ceil(size / blockSize) * blockSize;
    if (offset + padded > archive.byteLength) throw new Error(`Diesl application archive member is truncated: ${path}`);
    files.set(path, archive.slice(offset, offset + size));
    offset += padded;
  }
  if (!terminated) throw new Error("Diesl application archive has no terminator");
  if (!allZero(archive.subarray(offset))) throw new Error("Diesl application archive contains trailing data");
  return files;
}

function validateTarHeader(header) {
  if (tarText(header.subarray(257, 263)) !== "ustar") throw new Error("Diesl application archive must use ustar headers");
  const expected = tarOctal(header.subarray(148, 156), "header checksum");
  let actual = 0;
  for (let index = 0; index < header.length; index += 1) actual += index >= 148 && index < 156 ? 32 : header[index];
  if (actual !== expected) throw new Error("Diesl application archive header checksum mismatch");
}

async function validateApplicationFiles(files, records) {
  if (records.length !== files.size) throw new Error("Diesl application manifest does not match archive members");
  const seen = new Set();
  await Promise.all(records.map(async record => {
    if (!record || !safeRelativePath(record.path) || seen.has(record.path)) throw new Error("Diesl application manifest contains an unsafe or duplicate path");
    seen.add(record.path);
    const content = files.get(record.path);
    if (!content) throw new Error(`Diesl application archive is missing ${record.path}`);
    if (!Number.isSafeInteger(record.size) || content.byteLength !== record.size) throw new Error(`Diesl application file size mismatch: ${record.path}`);
    if (!/^[a-f0-9]{64}$/.test(record.sha256 || "") || await sha256Hex(content) !== record.sha256) {
      throw new Error(`Diesl application file integrity check failed: ${record.path}`);
    }
  }));
}

function hydrateFilesystem(files) {
  const root = new Directory(new Map());
  root.contents.set("tmp", new Directory(new Map()));
  root.contents.get("tmp").parent = root;

  for (const [path, bytes] of files) {
    const parts = path.split("/");
    const filename = parts.pop();
    let directory = root;
    for (const part of parts) {
      if (!directory.contents.has(part)) {
        const child = new Directory(new Map());
        child.parent = directory;
        directory.contents.set(part, child);
      }
      directory = directory.contents.get(part);
    }
    directory.contents.set(filename, new File(bytes));
  }

  return root;
}

function safeRelativePath(path) {
  return typeof path === "string" && path.length > 0 && !path.startsWith("/") && !path.includes("\\") && !path.includes("\0") &&
    path.split("/").every(component => component && component !== "." && component !== "..");
}

function safeAbsolutePath(path) {
  return path.startsWith("/") && safeRelativePath(path.slice(1));
}

function tarText(bytes) {
  const end = bytes.indexOf(0);
  return new TextDecoder("utf-8", { fatal: true }).decode(end === -1 ? bytes : bytes.subarray(0, end));
}

function tarOctal(bytes, label) {
  const value = tarText(bytes).trim();
  if (!/^[0-7]+$/.test(value)) throw new Error(`Diesl application archive has invalid ${label}`);
  return Number.parseInt(value, 8);
}

function allZero(bytes) {
  return bytes.every(byte => byte === 0);
}

async function sha256Hex(bytes) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
}

function hexToBase64(hex) {
  const bytes = Uint8Array.from(hex.match(/../g) || [], pair => Number.parseInt(pair, 16));
  return btoa(String.fromCharCode(...bytes));
}

function elapsed(started) {
  return performance.now() - started;
}

function escapeHtml(value) {
  const node = document.createElement("div");
  node.textContent = value;
  return node.innerHTML;
}


export { loadApplication, fetchJson, fetchRequired, validateRuntimeConfig, verifyBytes, hydrateFilesystem, escapeHtml };
