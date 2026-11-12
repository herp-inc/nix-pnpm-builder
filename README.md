# nix-pnpm-builder

Nix expressions for building pnpm projects.

## Features

- **No code generation**: Uses IFD, so there is no code generation and no hashes to update by hand
- **Private registries**: Supported by configuring `@scope:registry=<url>` in `.npmrc` and `netrc-file` in `nix.conf`
- **Efficient caching**: `buildPnpmGranularPackage` creates a derivation per dependency, so when the lockfile changes, only the changed dependencies are rebuilt. The same version of a dependency shares its store path even across different projects
- **Native modules**: Install scripts run for packages listed in `allowBuilds` in `pnpm-workspace.yaml`

| Function                   | How dependencies are laid out                                                                  | Suited for                                                   |
| -------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `buildPnpmPackage`         | Creates `node_modules` only during the build                                                   | Apps whose artifacts are produced by a bundler such as vite  |
| `buildPnpmGranularPackage` | Creates no `node_modules`; puts each dependency in its own store path and resolves them with a package map | Node apps that load dependencies at runtime without bundling |

## Usage

```nix
{
  inputs.pnpm-builder.url = "github:herp-inc/nix-pnpm-builder";

  outputs =
    { nixpkgs, pnpm-builder, ... }:
    let
      pkgs = import nixpkgs {
        system = "aarch64-darwin";
        overlays = [ pnpm-builder.overlays.default ];
      };
    in
    {
      packages.aarch64-darwin.default = pkgs.buildPnpmPackage { … };
    };
}
```

### buildPnpmPackage

```nix
pkgs.buildPnpmPackage {
  name = "app";
  src = ./.;
  buildPhase = "pnpm exec vite build";
  installPhase = "mv dist $out";
}
```

### buildPnpmGranularPackage

```nix
pkgs.buildPnpmGranularPackage {
  name = "server";
  src = ./.;
  # Equivalent to pnpm install --prod
  production = true;
  nativeBuildInputs = [ pkgs.esbuild ];
  buildPhase = "esbuild src/*.ts --outdir=dist --format=esm --platform=node";
  installPhase = "cp -R . $out";
}
```

At runtime, pass the environment variables in `passthru.nodeEnv`.

- `nodeEnv.loader`: Resolves with the bundled loader (`module.registerHooks`)
- `nodeEnv.experimental`: Resolves with node's `--experimental-package-map`

Tools that look up `node_modules` on their own, such as tsc and vite, cannot be used in the build.

### Common options

- `pnpmSrc`: The directory containing `pnpm-lock.yaml` and `.npmrc`. Defaults to `src`. If `src` is broad, narrowing this keeps source changes from re-triggering the lockfile import

## Limitations

- Uses IFD, so `allow-import-from-derivation` is required
- Dependencies without `integrity` (git or `file:` dependencies) are not supported
- Builds run inside the sandbox, so packages that download binaries from the network at install time fail

## Development

```sh
nix develop       # Shell with nodejs and pnpm
nix flake check   # Run the tests in tests/
```
