# Builds the same CLI (tests/app) with both builders and checks that each turns example.md into expected.json.
# Also runs a script (tests/native) whose dependencies need install scripts with both builders.
{
  pkgs,
  buildPnpmPackage,
  buildPnpmGranularPackage,
}:
let
  inherit (pkgs)
    lib
    runCommand
    writeClosure
    nodejs
    esbuild
    jq
    python3
    node-gyp
    ;

  src = ./app;

  # Bundles the app and its dependencies into a single file with vite
  bundled = buildPnpmPackage {
    name = "md2json-bundled";
    inherit src;
    buildPhase = ''
      runHook preBuild
      pnpm exec tsc
      pnpm exec vite build
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm644 dist/md2json.js $out/md2json.js
      runHook postInstall
    '';
  };

  # Only transpiles each file to JS with esbuild; dependencies are resolved through the package map
  granular = buildPnpmGranularPackage {
    name = "md2json-granular";
    inherit src;
    production = true;
    nativeBuildInputs = [ esbuild ];
    buildPhase = ''
      runHook preBuild
      for pkg in packages/*; do
        esbuild "$pkg"/src/*.ts --outdir="$pkg/dist" --format=esm --platform=node
      done
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp package.json $out
      for pkg in packages/*; do
        mkdir -p "$out/$pkg"
        cp -r "$pkg/package.json" "$pkg/dist" "$out/$pkg"
      done
      runHook postInstall
    '';
  };

  # pnpm runs the install scripts during pnpm install; the script runs while node_modules exists
  nativeBundled = buildPnpmPackage {
    name = "native-bundled";
    src = ./native;
    nativeBuildInputs = [
      python3
      node-gyp
    ];
    npm_config_nodedir = nodejs;
    buildPhase = ''
      runHook preBuild
      node main.cjs > output.json
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm644 output.json $out/output.json
      runHook postInstall
    '';
  };

  # Each package in allowBuilds gets its own derivation that runs its install scripts
  nativeGranular = buildPnpmGranularPackage {
    name = "native-granular";
    src = ./native;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp package.json main.cjs $out
      runHook postInstall
    '';
  };

  expectOutput =
    name: command:
    runCommand "test-${name}" { nativeBuildInputs = [ nodejs ]; } ''
      ${command} --pretty < ${./app/example.md} > output.json
      diff -u ${./expected.json} output.json
      touch $out
    '';

  expectNativeOutput =
    name: command:
    runCommand "test-${name}" { nativeBuildInputs = [ nodejs ]; } ''
      ${command} > output.json
      diff -u ${./native-expected.json} output.json
      touch $out
    '';
in
{
  build-package = expectOutput "build-package" "node ${bundled}/md2json.js";

  # Neither node_modules nor tarballs end up in the output closure
  build-package-closure = runCommand "test-build-package-closure" { } ''
    if grep -E 'node_modules|\.tgz$' ${writeClosure [ bundled ]}; then
      echo "closure of ${bundled} contains build-time dependencies" >&2
      exit 1
    fi
    touch $out
  '';

  build-granular-package-loader = expectOutput "build-granular-package-loader" "env ${lib.escapeShellArgs granular.nodeEnv.loader} node ${granular}/packages/cli/dist/cli.js";

  build-granular-package-experimental = expectOutput "build-granular-package-experimental" "env ${lib.escapeShellArgs granular.nodeEnv.experimental} node ${granular}/packages/cli/dist/cli.js";

  # With production = true, devDependencies are left out of the package map
  build-granular-package-production =
    runCommand "test-build-granular-package-production"
      {
        nativeBuildInputs = [ jq ];
      }
      ''
        jq -e '.packages | keys | map(select(startswith("vite@") or startswith("typescript@"))) == []' \
          ${granular}/.package-map.json
        touch $out
      '';

  build-package-native = expectNativeOutput "build-package-native" "cat ${nativeBundled}/output.json";

  build-granular-package-native = expectNativeOutput "build-granular-package-native" "env ${lib.escapeShellArgs nativeGranular.nodeEnv.loader} node ${nativeGranular}/main.cjs";
}
