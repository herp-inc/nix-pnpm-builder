import { readFileSync } from "node:fs";
import { Command } from "commander";
import { convert } from "@md2json/core";

const program = new Command("md2json")
  .description("Read Markdown with front matter from stdin and write it to stdout as JSON")
  .option("--pretty", "indent the output")
  .parse();

const document = convert(readFileSync(0, "utf8"));
process.stdout.write(`${JSON.stringify(document, null, program.opts().pretty ? 2 : undefined)}\n`);
