{
  lib,
  stdenv,
  nodejs,
  configHook,
}:
lib.extendMkDerivation {
  constructDrv = stdenv.mkDerivation;

  excludeDrvArgNames = [ "pnpmSrc" ];

  extendDrvArgs =
    finalAttrs:
    {
      # Directory containing pnpm-lock.yaml and .npmrc
      pnpmSrc ? finalAttrs.src,
      nativeBuildInputs ? [ ],
      ...
    }:
    {
      nativeBuildInputs = [
        nodejs
        (configHook { src = pnpmSrc; })
      ]
      ++ nativeBuildInputs;
    };
}
