{
  lib,
  stdenvNoCC,
  packageMap,
}:
lib.extendMkDerivation {
  constructDrv = stdenvNoCC.mkDerivation;

  excludeDrvArgNames = [
    "pnpmSrc"
    "production"
    "linkRootNodeModules"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      # Directory containing pnpm-lock.yaml and .npmrc
      pnpmSrc ? finalAttrs.src,
      production ? false,
      linkRootNodeModules ? false,
      postInstall ? "",
      passthru ? { },
      ...
    }:
    let
      depsMap = packageMap {
        src = pnpmSrc;
        inherit production linkRootNodeModules;
      };
    in
    {
      postInstall = ''
        ${depsMap.install} $out
      ''
      + postInstall;

      passthru = {
        packageMap = depsMap;
        nodeEnv =
          let
            mapPath = "${finalAttrs.finalPackage}/.package-map.json";
          in
          {
            # Resolve with our own loader.cjs (module.registerHooks)
            loader = [
              "NODE_OPTIONS=--require=${depsMap.loader}"
              "PACKAGE_MAP_PATH=${mapPath}"
            ];
            # Resolve with node's --experimental-package-map. node fails to start on versions without this flag (e.g. 24.18)
            experimental = [ "NODE_OPTIONS=--experimental-package-map=${mapPath}" ];
          };
      }
      // passthru;
    };
}
