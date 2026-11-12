# Uses pnpm's package map (node_modules/.package-map.json) to put dependencies in the store, one derivation per package.
# 1. Runs pnpm install with a lockfile whose tarballs are all replaced by an empty one, and matches the package map
#    pnpm writes against the lockfile to produce a JSON
# 2. Extracts each package in the package map from its tarball
#    For packages in allowBuilds, runs lifecycle scripts using their dependency closure
# 3. Rewrites the urls in the package map to store paths
# Example:
# packageMap = pnpm-builder.packageMap { src = ./.; };
# installPhase = "cp -r . $out; ${packageMap.install} $out";
{
  lib,
  stdenv,
  stdenvNoCC,
  runCommand,
  writeText,
  writeShellScript,
  jq,
  yq,
  openssl,
  python3,
  nodejs,
  pnpm,
  pnpmLib,
}:
{
  src,
  # Equivalent to pnpm install --prod
  production ? false,
  # Symlink the root workspace's direct dependencies to node_modules/<name>
  linkRootNodeModules ? false,
}:
let
  manifests =
    if builtins.isPath src then
      lib.fileset.toSource {
        root = src;
        fileset = lib.fileset.fileFilter (
          file:
          builtins.elem file.name [
            "package.json"
            "pnpm-lock.yaml"
            "pnpm-workspace.yaml"
          ]
        ) src;
      }
    else
      src;

  # The package map depends only on the lockfile, and pnpm does not look inside the tarballs.
  # Installing with every package replaced by this single tarball yields the package map without extracting the real ones
  placeholderTarball =
    runCommand "pnpm-package-map-placeholder" { nativeBuildInputs = [ openssl ]; }
      ''
        mkdir -p package $out
        echo '{}' > package/package.json
        tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - package | gzip -n > $out/package.tgz
        echo "sha512-$(openssl dgst -sha512 -binary $out/package.tgz | base64 -w0)" > $out/integrity
      '';

  inherit (stdenv) hostPlatform;
  supportedArchitectures = {
    os = [
      (
        if hostPlatform.isDarwin then
          "darwin"
        else if hostPlatform.isLinux then
          "linux"
        else
          hostPlatform.parsed.kernel.name
      )
    ];
    cpu = [
      (
        if hostPlatform.isx86_64 then
          "x64"
        else if hostPlatform.isAarch64 then
          "arm64"
        else
          hostPlatform.parsed.cpu.name
      )
    ];
    libc = [ (if hostPlatform.isMusl then "musl" else "glibc") ];
  };

  resolved = stdenvNoCC.mkDerivation {
    name = "pnpm-package-map${lib.optionalString production "-prod"}.json";
    src = manifests;

    nativeBuildInputs = [
      nodejs
      pnpm
      jq
      yq
    ];

    dontBuild = true;
    dontFixup = true;

    installPhase = ''
      export HOME=$TMPDIR CI=true
      # The lockfile's tarballs are replaced, so it fails pnpm's supply-chain verification
      export PNPM_CONFIG_TRUST_LOCKFILE=true
      export PNPM_CONFIG_ENABLE_GLOBAL_VIRTUAL_STORE=false
      export PNPM_CONFIG_NODE_EXPERIMENTAL_PACKAGE_MAP=true
      export PNPM_CONFIG_PACKAGE_IMPORT_METHOD=copy

      if [ -f pnpm-workspace.yaml ]; then
        yq . pnpm-workspace.yaml > $TMPDIR/workspace.json
      else
        echo '{}' > $TMPDIR/workspace.json
      fi
      yq . pnpm-lock.yaml > $TMPDIR/lock.json
      jq --arg integrity "$(cat ${placeholderTarball}/integrity)" --arg tarball "file://${placeholderTarball}/package.tgz" \
        '.packages |= map_values(.resolution = { integrity: $integrity, tarball: $tarball })' \
        $TMPDIR/lock.json > pnpm-lock.yaml

      # Overrides supportedArchitectures in pnpm-workspace.yaml so that only optional dependencies matching the host are installed
      pnpm install --frozen-lockfile --offline --ignore-scripts --store-dir $TMPDIR/store \
        ${
          lib.concatMapStringsSep " " (
            { name, value }: lib.concatMapStringsSep " " (v: "--${name} ${v}") value
          ) (lib.attrsToList supportedArchitectures)
        } \
        ${lib.optionalString production "--prod"}

      node ${./resolve.mjs} . $TMPDIR/lock.json $TMPDIR/workspace.json > $out
    '';
  };

  inherit (lib.importJSON resolved) packages workspaces;

  sanitize = builtins.replaceStrings [ "@" "/" "(" ")" ] [ "" "-" "_" "_" ];

  registries = pnpmLib.registriesOf src;
  fetchPackage =
    pkg:
    pnpmLib.fetchTarball registries (
      {
        inherit (pkg) name version integrity;
      }
      // lib.optionalAttrs (pkg ? tarball) { inherit (pkg) tarball; }
    );

  # Packages go under node_modules/<name> rather than directly in the store path,
  # because tools like dd-trace identify which package a file belongs to from node_modules/<name> in its path
  packageDir = id: "node_modules/${packages.${id}.name}";
  rootIn = drv: id: "${drv}/${packageDir id}";

  extract = id: ''
    mkdir -p $out/${packageDir id}
    tar -xzf $src -C $out/${packageDir id} --strip-components=1 \
      --no-same-owner --no-same-permissions --delay-directory-restore
    chmod -R u+rwX $out
  '';

  loader = ./loader.cjs;

  # usage: link-bins <bin-dir> <package-map-path or ""> <name> <package-dir> ...
  # If the package map path is empty, it is assumed to be passed via NODE_OPTIONS and PACKAGE_MAP_PATH
  linkBins = writeShellScript "pnpm-package-map-link-bins" ''
    set -euo pipefail
    binDir=$1 map=$2
    shift 2
    mkdir -p "$binDir"
    env=""
    flags=""
    if [ -n "$map" ]; then
      env="PACKAGE_MAP_PATH=$map"
      flags="--require ${loader}"
    fi
    while [ $# -gt 0 ]; do
      name=$1 pkg=$2
      shift 2
      ${jq}/bin/jq -r --arg name "$name" '
        if (.bin | type) == "string" then [($name | split("/") | last), .bin]
        elif (.bin | type) == "object" then (.bin | to_entries[] | [.key, .value])
        else empty end | @tsv
      ' "$pkg/package.json" | while IFS=$'\t' read -r bin target; do
        printf '#!${stdenv.shell}\n%s exec ${nodejs}/bin/node %s "%s" "$@"\n' "$env" "$flags" "$pkg/$target" > "$binDir/$bin"
        chmod +x "$binDir/$bin"
      done
    done
  '';

  extractedPackages = lib.mapAttrs (
    id: pkg:
    stdenvNoCC.mkDerivation {
      name = "pnpm-pm-" + sanitize id;
      src = fetchPackage pkg;
      dontUnpack = true;
      dontFixup = true;
      installPhase = extract id;
    }
  ) packages;

  registryDependencies =
    id: lib.filter (dep: packages ? ${dep}) (lib.attrValues packages.${id}.dependencies);

  closureOf =
    id:
    map (entry: entry.key) (
      builtins.genericClosure {
        startSet = [ { key = id; } ];
        operator = entry: map (key: { inherit key; }) (registryDependencies entry.key);
      }
    );

  selfPlaceholder = "@PNPM_PACKAGE_MAP_SELF@";

  # Dependencies are the extracted packages before their scripts run (avoids cycles between packages that need building).
  # Install scripts may require.resolve the built package's dependencies from inside a helper
  # (napi-postinstall looks for unrs-resolver's per-platform binding), so every package in the closure can see all of them
  buildStorePackage =
    id: pkg:
    let
      closure = closureOf id;
      directDependencies = lib.filterAttrs (_: dep: dep != id && packages ? ${dep}) pkg.dependencies;
      linkDirectDependencies = lib.concatStrings (
        lib.mapAttrsToList (alias: dep: ''
          mkdir -p "$(dirname "$out/node_modules/${alias}")"
          ln -s ${rootIn extractedPackages.${dep} dep} "$out/node_modules/${alias}"
        '') directDependencies
      );
      unlinkDirectDependencies = lib.concatStrings (
        lib.mapAttrsToList (alias: _: ''
          rm "$out/node_modules/${alias}"
          ${lib.optionalString (lib.hasPrefix "@" alias) ''rmdir "$(dirname "$out/node_modules/${alias}")" 2>/dev/null || true''}
        '') directDependencies
      );
    in
    stdenv.mkDerivation {
      name = "pnpm-pm-" + sanitize id;
      src = fetchPackage pkg;
      dontUnpack = true;
      dontFixup = true;

      nativeBuildInputs = [
        nodejs
        jq
        python3
      ];

      buildMap = builtins.toJSON {
        packages = lib.genAttrs closure (dep: {
          url = if dep == id then selfPlaceholder else "file://${rootIn extractedPackages.${dep} dep}";
          dependencies = pkg.dependencies // packages.${dep}.dependencies;
        });
      };
      passAsFile = [ "buildMap" ];

      installPhase = ''
        ${extract id}
        sed "s|${selfPlaceholder}|file://$out/${packageDir id}|g" "$buildMapPath" > "$TMPDIR/package-map.json"
        export PACKAGE_MAP_PATH="$TMPDIR/package-map.json" NODE_OPTIONS="--require ${loader}"
        export HOME="$TMPDIR" INIT_CWD="$out/${packageDir id}" npm_config_nodedir=${nodejs}
        export npm_package_name=${lib.escapeShellArg pkg.name} npm_package_version=${lib.escapeShellArg pkg.version}
        ${linkBins} "$TMPDIR/bin" "" ${
          lib.concatStringsSep " " (
            lib.mapAttrsToList (
              _: dep: "${lib.escapeShellArg packages.${dep}.name} ${rootIn extractedPackages.${dep} dep}"
            ) directDependencies
          )
        }
        # npm and node-gyp live outside the build package map, so run them without it
        for tool in npm node-gyp; do
          script=${nodejs}/lib/node_modules/npm/bin/npm-cli.js
          [ "$tool" = node-gyp ] && script=${nodejs}/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js
          printf '#!${stdenv.shell}\nNODE_OPTIONS= exec ${nodejs}/bin/node %s "$@"\n' "$script" > "$TMPDIR/bin/$tool"
          chmod +x "$TMPDIR/bin/$tool"
        done
        export PATH="$TMPDIR/bin:$PATH"

        # Tools running without the package map (node-gyp, and the node it spawns for
        # <!(node -e "require('nan')") in binding.gyp) find direct dependencies through node_modules
        ${linkDirectDependencies}

        cd $out/${packageDir id}
        ran=""
        for event in preinstall install postinstall; do
          script=$(jq -r --arg event "$event" '.scripts[$event] // empty' package.json)
          if [ -n "$script" ]; then
            ran=1
            echo "running $event: $script"
            npm_lifecycle_event="$event" sh -c "$script"
          fi
        done
        if [ -z "$ran" ] && [ -f binding.gyp ]; then
          npm_lifecycle_event=install node-gyp rebuild
        fi

        ${unlinkDirectDependencies}

        # Scripts may hardlink files from other store paths (esbuild)
        find "$out" -type f -links +1 -exec sh -c 'cp "$1" "$1.tmp" && mv "$1.tmp" "$1"' _ {} \;
      '';
    };

  storePackages = lib.mapAttrs (
    id: pkg: if pkg.build then buildStorePackage id pkg else extractedPackages.${id}
  ) packages;

  # With the relative url "./.", files directly under the root are treated as outside the package map, so it is replaced with an absolute url at install time
  rootPlaceholder = "@PNPM_PACKAGE_MAP_ROOT@";
  packageMap = {
    packages =
      lib.mapAttrs (id: pkg: {
        url = "file://${rootIn storePackages.${id} id}";
        inherit (pkg) dependencies;
      }) packages
      // lib.mapAttrs (_: ws: {
        url = rootPlaceholder + lib.optionalString (ws.path != ".") "/${ws.path}";
        inherit (ws) dependencies;
      }) workspaces;
  };
  packageMapFile = writeText "package-map.json" (builtins.toJSON packageMap);

  # Wrap the bins of each workspace's direct dependencies in .bin, with the loader enabled
  install = writeShellScript "pnpm-package-map-install" ''
    set -euo pipefail
    dir=$(realpath "$1")
    sed "s|${rootPlaceholder}|file://$dir|g" ${packageMapFile} > "$dir/.package-map.json"
    ${lib.concatStrings (
      lib.mapAttrsToList (
        _: ws:
        let
          deps = lib.filterAttrs (_: dep: storePackages ? ${dep}) ws.dependencies;
        in
        # Some workspaces are not placed in the output, so only link bins for those whose directory exists
        lib.optionalString (deps != { }) ''
          if [ -d "$dir/${ws.path}" ]; then
            ${linkBins} "$dir/${ws.path}/.bin" "$dir/.package-map.json" ${
              lib.concatStringsSep " " (
                lib.mapAttrsToList (
                  _: dep: "${lib.escapeShellArg packages.${dep}.name} ${rootIn storePackages.${dep} dep}"
                ) deps
              )
            }
          fi
        ''
      ) workspaces
    )}
    ${lib.optionalString linkRootNodeModules (
      lib.concatStrings (
        lib.mapAttrsToList
          (
            alias: dep:
            let
              target =
                if storePackages ? ${dep} then
                  rootIn storePackages.${dep} dep
                else
                  "$dir/${workspaces.${dep}.path}";
            in
            ''
              mkdir -p "$(dirname "$dir/node_modules/${alias}")"
              ln -s "${target}" "$dir/node_modules/${alias}"
            ''
          )
          (
            lib.filterAttrs (
              _: dep: dep != rootId && (storePackages ? ${dep} || workspaces ? ${dep})
            ) rootWorkspace.dependencies
          )
      )
    )}
  '';

  rootId = lib.findFirst (id: workspaces.${id}.path == ".") (throw "root workspace not found") (
    lib.attrNames workspaces
  );
  rootWorkspace = workspaces.${rootId};
in
{
  inherit
    nodejs
    loader
    resolved
    packageMap
    packageMapFile
    storePackages
    install
    ;
}
