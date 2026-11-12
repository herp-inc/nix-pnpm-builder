// Exercises one native dependency per install-script pattern and prints a deterministic result
const path = require("node:path");
const esbuild = require("esbuild");
const { ResolverFactory } = require("unrs-resolver");
const diskusage = require("diskusage");

const resolved = new ResolverFactory({}).sync(__dirname, "./main.cjs");

process.stdout.write(
  `${JSON.stringify(
    {
      esbuild: esbuild.transformSync("const x: number = 1", { loader: "ts" }).code,
      unrsResolver: path.relative(__dirname, resolved.path),
      diskusage: typeof diskusage.checkSync("/").total,
    },
    null,
    2,
  )}\n`,
);
