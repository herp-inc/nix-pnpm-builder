{
  description = "pnpm package builder for Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      mkPnpmBuilder =
        pkgs:
        let
          builder = pkgs.callPackage ./. { };
        in
        {
          buildPnpmPackage = builder.buildPackage;
          buildPnpmGranularPackage = builder.buildGranularPackage;
          pnpmConfigHook = builder.configHook;
        };
    in
    {
      overlays.default = final: _prev: mkPnpmBuilder final;

      legacyPackages = forAllSystems (system: mkPnpmBuilder nixpkgs.legacyPackages.${system});

      checks = forAllSystems (
        system:
        import ./tests {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (self.legacyPackages.${system}) buildPnpmPackage buildPnpmGranularPackage;
        }
      );

      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = with nixpkgs.legacyPackages.${system}; [
            nodejs
            pnpm
          ];
        };
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
