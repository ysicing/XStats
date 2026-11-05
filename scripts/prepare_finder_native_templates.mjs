// SPDX-License-Identifier: AGPL-3.0-or-later

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const revision = "9550fc8163c64774f4400b98e0542823da59f8b6";
const checkout = resolve(process.argv[2] ?? "");
assert.ok(process.argv[2], "Pass a checkout of den-frie-vilje/cupertino-files.");
assert.equal(execFileSync("git", ["-C", checkout, "rev-parse", "HEAD"], {
  encoding: "utf8",
}).trim(), revision);
const { decodeIwaData, KeynoteDocument, NumbersDocument, PagesDocument, ZipReader } = await import(
  pathToFileURL(join(checkout, "src/index.ts")).href
);
const templates = fileURLToPath(new URL(
  "../Packages/XStatsKit/Sources/FinderDocuments/Templates/", import.meta.url,
));
const load = (path) => new Uint8Array(readFileSync(join(checkout, path)));
const pagesBytes = load("data/blanks/blank.pages");
const numbersBytes = load("fixtures/pypi-numbers-parser-v14.1.1-empty-template.numbers");
const keynote = KeynoteDocument.load(load("data/blanks/blank.key"));

// 上游移除幻灯片后仍保留孤立存档；清空非母版文字，防止分发示例内容。
const masterIdentifiers = new Set(keynote.store.components
  .filter((component) => /^Index\/(?:TemplateSlide|MasterSlide)/.test(component.name))
  .flatMap((component) => component.objects.map((object) => object.identifier)));
for (const storage of keynote.textStorages()) {
  if (!masterIdentifiers.has(storage.id)) storage.setText("");
}
const keynoteBytes = keynote.save();
const pages = PagesDocument.load(pagesBytes);
const numbers = NumbersDocument.load(numbersBytes);
const savedKeynote = KeynoteDocument.load(keynoteBytes);
assert.equal(pages.bodyText, "");
assert.equal(pages.comments().length, 0);
assert.equal(numbers.sheets().length, 1);
assert.equal(numbers.tables().length, 1);
assert.equal(numbers.tables()[0].cells().length, 0);
assert.equal(savedKeynote.slides().length, 1);
assert.equal(savedKeynote.slides()[0].notes, "");
assert.ok(savedKeynote.slides()[0].textStorages().every((storage) => storage.text === ""));
assert.ok(savedKeynote.textStorages()
  .filter((storage) => !masterIdentifiers.has(storage.id))
  .every((storage) => storage.text === ""));
for (const [extension, document, bytes] of [
  ["pages", pages, pagesBytes],
  ["numbers", numbers, numbersBytes],
  ["key", savedKeynote, keynoteBytes],
]) {
  const compatibility = document.compatibility();
  assert.ok(compatibility.canRoundTrip);
  assert.ok(compatibility.formatVersion.parts[0] <= 14);
  const archive = ZipReader.parse(bytes);
  for (const entry of archive.entries.filter((entry) => entry.name.endsWith(".iwa"))) {
    const decoded = Buffer.from(decodeIwaData(archive.read(entry))).toString("utf8");
    assert.ok(!/Goals for Q1|project-aurora|Engineering Team|Launch beta to 500 users/.test(decoded));
  }
  const destination = join(templates, `blank.${extension}`);
  if (process.argv.includes("--check")) {
    assert.deepEqual(new Uint8Array(readFileSync(destination)), bytes);
  } else {
    writeFileSync(destination, bytes);
  }
  console.log(`${extension}: ${bytes.length} bytes; blank content verified`);
}
