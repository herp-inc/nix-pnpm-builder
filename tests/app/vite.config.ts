import { defaultServerConditions, defineConfig } from "vite";

export default defineConfig({
  ssr: {
    // Bundle all dependencies into the output as well
    noExternal: true,
    resolve: {
      conditions: ["source", ...defaultServerConditions],
    },
  },
  build: {
    ssr: "packages/cli/src/cli.ts",
    outDir: "dist",
    rollupOptions: {
      output: { entryFileNames: "md2json.js" },
    },
  },
});
