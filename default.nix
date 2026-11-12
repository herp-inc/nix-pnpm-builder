{ callPackage }:
let
  pnpmLib = callPackage ./lib.nix { };
  configHook = callPackage ./config-hook.nix { inherit pnpmLib; };
  buildPackage = callPackage ./build-package.nix { inherit configHook; };
  packageMap = callPackage ./package-map { inherit pnpmLib; };
in
{
  lib = pnpmLib;
  inherit configHook buildPackage packageMap;
  buildGranularPackage = callPackage ./build-granular-package.nix { inherit packageMap; };
}
