{
  lib,
  runCommand,
  yq,
}:
rec {
  readLockfile =
    src:
    lib.importJSON (
      runCommand "pnpm-lock.json" { nativeBuildInputs = [ yq ]; } "yq . ${src + "/pnpm-lock.yaml"} > $out"
    );

  # @scope:registry=<url> in .npmrc
  registriesOf =
    src:
    let
      npmrc = src + "/.npmrc";
      lines = lib.splitString "\n" (if builtins.pathExists npmrc then builtins.readFile npmrc else "");
      parse =
        line:
        let
          m = builtins.match "[[:space:]]*(@[^:]+):registry[[:space:]]*=[[:space:]]*(.+[^[:space:]])[[:space:]]*" line;
        in
        lib.optional (m != null) {
          name = builtins.elemAt m 0;
          value = lib.removeSuffix "/" (builtins.elemAt m 1);
        };
    in
    {
      default = "https://registry.npmjs.org";
    }
    // builtins.listToAttrs (lib.concatMap parse lines);

  # a key of packages in the lockfile (<name>@<version>)
  splitPackageKey =
    key:
    let
      m = builtins.match "(@?[^@]+)@(.+)" (lib.removePrefix "/" key);
    in
    if m == null then
      throw "pnpm-builder: cannot parse package key ${key}"
    else
      {
        name = builtins.elemAt m 0;
        version = builtins.elemAt m 1;
      };

  tarballUrl =
    registries:
    { name, version }:
    let
      scope = builtins.head (lib.splitString "/" name);
      registry =
        if lib.hasPrefix "@" name then registries.${scope} or registries.default else registries.default;
    in
    "${registry}/${name}/-/${baseNameOf name}-${version}.tgz";

  # tarball: resolution.tarball in the lockfile (only written when the package is not fetched from the registry)
  fetchTarball =
    registries:
    {
      name,
      version,
      integrity,
      tarball ? tarballUrl registries { inherit name version; },
    }:
    import <nix/fetchurl.nix> {
      url = tarball;
      hash = integrity;
    };
}
