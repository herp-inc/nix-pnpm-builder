{
  lib,
  makeSetupHook,
  pnpm,
  runCommand,
  writeScript,
  yq,
  pnpmLib,
}:
{
  # Directory containing pnpm-lock.yaml and .npmrc
  src,
}:
let
  lockfile = src + "/pnpm-lock.yaml";
  lockData = pnpmLib.readLockfile src;
  registries = pnpmLib.registriesOf src;

  fetchPackage =
    key: pkg:
    pnpmLib.fetchTarball registries (
      pnpmLib.splitPackageKey key
      // {
        inherit (pkg.resolution) integrity;
      }
      // lib.optionalAttrs (pkg.resolution ? tarball) { inherit (pkg.resolution) tarball; }
    );

  patchedLockfile = runCommand "patched-pnpm-lock.yaml" {
    nativeBuildInputs = [ yq ];
    value = builtins.toJSON (
      lockData
      // {
        packages = lib.mapAttrs (
          key: pkg:
          pkg
          // {
            resolution = pkg.resolution // {
              tarball = "file://${fetchPackage key pkg}";
            };
          }
        ) lockData.packages;
      }
    );
    passAsFile = [ "value" ];
  } "yq -y . $valuePath > $out";
in
makeSetupHook
  {
    name = "pnpm-builder-config-hook";
    propagatedBuildInputs = [ pnpm ];
  }
  (
    writeScript "pnpm-builder-config-hook.sh" ''
      #!@shell@
      # shellcheck shell=bash

      pnpmConfigHook() {
          export HOME=$(mktemp -d)
          export STORE_PATH=$(mktemp -d)
          export CI=true
          # The lockfile's tarballs are rewritten to file://, so it fails pnpm's supply-chain verification
          export PNPM_CONFIG_TRUST_LOCKFILE=true
          export PNPM_CONFIG_ENABLE_GLOBAL_VIRTUAL_STORE=false
          cp "${patchedLockfile}" pnpm-lock.yaml
          chmod +w pnpm-lock.yaml

          pnpm config set store-dir "$STORE_PATH"
          pnpm config set package-import-method clone-or-copy
          pnpm install --frozen-lockfile --offline
      }

      # The patched lockfile and the node_modules/.pnpm/lock.yaml pnpm writes from it reference the tarballs' store paths;
      # leaving them in an output pulls every tarball into its closure
      pnpmRestoreLockfileHook() {
          local output dir
          for output in $(getAllOutputNames); do
              dir="''${!output}"
              rm -f "$dir/node_modules/.pnpm/lock.yaml"
              if [ -f "$dir/pnpm-lock.yaml" ]; then
                  cp "${lockfile}" "$dir/pnpm-lock.yaml"
              fi
          done
      }

      postConfigureHooks+=(pnpmConfigHook)
      postInstallHooks+=(pnpmRestoreLockfileHook)
    ''
  )
