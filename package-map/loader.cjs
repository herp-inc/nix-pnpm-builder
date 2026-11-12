// Resolves bare specifiers with a package map, using module.registerHooks.
// Usage: PACKAGE_MAP_PATH=<package-map.json> node --require <this file> ...
// The package map has the same format as node's --experimental-package-map.
// Package paths, exports and conditions are left to Node: once the package root is known from the package map,
// the specifier is resolved as a self-reference from inside that package (or as a plain path when it has no exports).
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const Module = require("node:module");
const { createRequire, isBuiltin, registerHooks } = Module;
const { fileURLToPath, pathToFileURL } = require("node:url");

const mapPath = process.env.PACKAGE_MAP_PATH;
if (mapPath === undefined || mapPath === "") {
  throw new Error(`${__filename}: PACKAGE_MAP_PATH is not set`);
}
const map = JSON.parse(fs.readFileSync(mapPath, "utf8"));
const mapFile = path.resolve(mapPath);
const mapURL = pathToFileURL(mapFile);

// url is relative to the package map file
const rootOf = (id) =>
  fileURLToPath(new URL(map.packages[id].url, mapURL)).replace(/\/$/, "");

const packageIdByRoot = new Map();
for (const id of Object.keys(map.packages)) {
  packageIdByRoot.set(rootOf(id), id);
}

const issuerByDir = new Map();
const issuerOf = (dir) => {
  if (issuerByDir.has(dir)) {
    return issuerByDir.get(dir);
  }
  const parent = path.dirname(dir);
  const id =
    packageIdByRoot.get(dir) ?? (parent === dir ? undefined : issuerOf(parent));
  issuerByDir.set(dir, id);
  return id;
};

// a workspace in the package map may be left out of the output
const manifests = new Map();
const manifestOf = (root) => {
  let manifest = manifests.get(root);
  if (manifest === undefined) {
    const manifestPath = path.join(root, "package.json");
    manifest = fs.existsSync(manifestPath)
      ? JSON.parse(fs.readFileSync(manifestPath, "utf8"))
      : {};
    manifests.set(root, manifest);
  }
  return manifest;
};

const isBare = (specifier) =>
  !specifier.startsWith(".") &&
  !specifier.startsWith("/") &&
  !specifier.startsWith("#") &&
  !specifier.includes(":");

const splitSpecifier = (specifier) => {
  const parts = specifier.split("/");
  const nameLength = specifier.startsWith("@") ? 2 : 1;
  return {
    name: parts.slice(0, nameLength).join("/"),
    subpath: parts.slice(nameLength).join("/"),
  };
};

// same codes and messages as node's --experimental-package-map
const codedError = (code, message) =>
  Object.assign(new Error(message), { code });

// registerHooks does not reach Module._resolveFilename and Module._findPath called directly,
// which dd-trace (its require-in-the-middle) uses to tell which package a required file belongs to.
// Each package sits at <store path>/node_modules/<name>, so adding that node_modules to the lookup paths
// lets them find the dependency the same way they would in a node_modules tree.
// A dependency under an alias, or a workspace, is not found this way and is left to the resolve hook.
const resolveLookupPaths = Module._resolveLookupPaths;
Module._resolveLookupPaths = function (request, parent, ...rest) {
  const paths = resolveLookupPaths.call(this, request, parent, ...rest);
  if (
    paths === null ||
    !isBare(request) ||
    isBuiltin(request) ||
    typeof parent?.filename !== "string"
  ) {
    return paths;
  }
  const issuer = issuerOf(path.dirname(parent.filename));
  const { name } = splitSpecifier(request);
  const target =
    issuer === undefined
      ? undefined
      : map.packages[issuer].dependencies?.[name];
  if (target === undefined || map.packages[target] === undefined) {
    return paths;
  }
  const suffix = `${path.sep}node_modules${path.sep}${name}`;
  const root = rootOf(target);
  if (!root.endsWith(suffix)) {
    return paths;
  }
  return [root.slice(0, -name.length - 1), ...paths];
};

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (
      !isBare(specifier) ||
      isBuiltin(specifier) ||
      !context.parentURL?.startsWith("file:")
    ) {
      return nextResolve(specifier, context);
    }
    const parentPath = fileURLToPath(context.parentURL);
    const issuer = issuerOf(path.dirname(parentPath));
    if (issuer === undefined) {
      throw codedError(
        "ERR_PACKAGE_MAP_EXTERNAL_FILE",
        `Cannot resolve "${specifier}" from "${parentPath}": file is not within any package defined in ${mapFile}`,
      );
    }
    const isRequire = context.conditions?.includes("require") ?? false;
    const { name, subpath } = splitSpecifier(specifier);
    // Node checks self-references (only available with exports) before dependencies
    const own = manifestOf(rootOf(issuer));
    if (name === own.name && own.exports !== undefined) {
      return nextResolve(specifier, context);
    }
    const target = map.packages[issuer].dependencies?.[name];
    if (target === undefined || map.packages[target] === undefined) {
      throw isRequire
        ? codedError("MODULE_NOT_FOUND", `Cannot find module '${specifier}'`)
        : codedError(
            "ERR_MODULE_NOT_FOUND",
            `Cannot find package '${name}' imported from ${parentPath}`,
          );
    }

    const root = rootOf(target);
    const manifest = manifestOf(root);
    if (manifest.exports !== undefined) {
      // the alias in dependencies may differ from the package's own name
      const selfReference =
        subpath === "" ? manifest.name : `${manifest.name}/${subpath}`;
      const insideTarget = path.join(root, "package.json");
      if (isRequire) {
        return {
          url: pathToFileURL(createRequire(insideTarget).resolve(selfReference))
            .href,
          shortCircuit: true,
        };
      }
      return nextResolve(selfReference, {
        ...context,
        parentURL: pathToFileURL(insideTarget).href,
      });
    }
    // without exports, ESM resolves a subpath to the exact file and the package itself through main like require does
    if (isRequire || subpath === "") {
      try {
        return {
          url: pathToFileURL(
            createRequire(__filename).resolve(path.join(root, subpath)),
          ).href,
          shortCircuit: true,
        };
      } catch (error) {
        if (!isRequire && error.code === "MODULE_NOT_FOUND") {
          error.code = "ERR_MODULE_NOT_FOUND";
        }
        throw error;
      }
    }
    return nextResolve(pathToFileURL(path.join(root, subpath)).href, context);
  },
});
