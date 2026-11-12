// Usage: node resolve.mjs <project-root> <lockfile.json> <workspace.json>
// Matches the package map that pnpm install wrote to node_modules/.package-map.json against the original lockfile
// and prints it, so that Nix can fetch each package from its tarball.
// Tarball URLs are built on the Nix side from the registries in .npmrc.
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

const [root, lockfilePath, workspacePath] = process.argv.slice(2);
const nodeModules = path.join(root, 'node_modules');
const readJson = (file) => JSON.parse(readFileSync(file, 'utf8'));
const packageMap = readJson(path.join(nodeModules, '.package-map.json'));
const lockfile = readJson(lockfilePath);
const workspace = readJson(workspacePath) ?? {};

const allowBuilds = new Set(
  Object.entries(workspace.allowBuilds ?? {})
    .filter(([, allowed]) => allowed === true)
    .map(([name]) => name)
    .concat(workspace.onlyBuiltDependencies ?? []),
);

const withoutPeers = (id) => {
  const index = id.indexOf('(');
  return index === -1 ? id : id.slice(0, index);
};

const splitNameVersion = (key) => {
  const index = key.indexOf('@', 1);
  return { name: key.slice(0, index), version: key.slice(index + 1) };
};

const locationOf = (entry) => path.resolve(nodeModules, entry.url);

// Unsupported optional dependencies are still listed in the package map but are not installed, so drop them
const entries = Object.fromEntries(
  Object.entries(packageMap.packages).filter(([, entry]) => existsSync(locationOf(entry))),
);
const dependenciesOf = (entry) =>
  Object.fromEntries(Object.entries(entry.dependencies ?? {}).filter(([, id]) => id in entries));

const packages = {};
const workspaces = {};
for (const [id, entry] of Object.entries(entries)) {
  const dependencies = dependenciesOf(entry);
  if (lockfile.snapshots?.[id] === undefined) {
    workspaces[id] = { path: path.relative(root, locationOf(entry)) || '.', dependencies };
    continue;
  }
  const key = withoutPeers(id);
  const { name, version } = splitNameVersion(key);
  const resolution = lockfile.packages?.[key]?.resolution ?? {};
  if (resolution.integrity === undefined) {
    throw new Error(`${id}: only registry tarballs with integrity are supported`);
  }
  packages[id] = {
    name,
    version,
    tarball: resolution.tarball,
    integrity: resolution.integrity,
    build: allowBuilds.has(name),
    dependencies,
  };
}

process.stdout.write(`${JSON.stringify({ packages, workspaces }, null, 2)}\n`);
