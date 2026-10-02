#!/usr/bin/env node
// Created by Claude — Classification: INTERNAL
//
// Generates src-tauri/resources/THIRD_PARTY_LICENSES.txt: the license (and NOTICE) text
// of every third-party package that ships inside Muya — Rust crates linked into the
// binary (normal dependencies for macOS arm64; build/dev-only crates excluded) and the
// npm packages bundled into the web UI (npm's `.prod` set). MIT/BSD/Apache-2.0/ISC/OFL
// all require their text to travel with a binary distribution.
//
//   node tools/third-party-notices.mjs          # regenerate
//   node tools/third-party-notices.mjs --check  # exit 1 if the committed file is stale
//
// Run it before a release whenever dependencies changed.

import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT = join(ROOT, "src-tauri/resources/THIRD_PARTY_LICENSES.txt");
const TARGET = "aarch64-apple-darwin";
const LICENSE_FILE = /^(licen[cs]e|copying|notice|copyright|unlicense)([-._].*)?$/i;

function licenseFiles(dir) {
  if (!dir || !existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => LICENSE_FILE.test(f))
    .sort()
    .map((f) => {
      try {
        return { file: f, text: readFileSync(join(dir, f), "utf8").trim() };
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

function rustPackages() {
  const meta = JSON.parse(
    execFileSync("cargo", ["metadata", "--format-version", "1", "--filter-platform", TARGET, "--locked"], {
      cwd: join(ROOT, "src-tauri"),
      maxBuffer: 256 * 1024 * 1024,
    }).toString(),
  );
  const byId = new Map(meta.packages.map((p) => [p.id, p]));
  const nodes = new Map(meta.resolve.nodes.map((n) => [n.id, n]));
  // Walk NORMAL dependency edges from the app crate: what is linked into the binary.
  const seen = new Set();
  const stack = [meta.resolve.root];
  while (stack.length) {
    const id = stack.pop();
    if (seen.has(id)) continue;
    seen.add(id);
    for (const d of nodes.get(id)?.deps ?? []) {
      if (d.dep_kinds.some((k) => k.kind === null)) stack.push(d.pkg);
    }
  }
  seen.delete(meta.resolve.root);
  return [...seen].map((id) => {
    const p = byId.get(id);
    return {
      eco: "Rust crate",
      name: p.name,
      version: p.version,
      license: p.license ?? (p.license_file ? `see ${p.license_file}` : "UNKNOWN"),
      url: p.repository ?? `https://crates.io/crates/${p.name}`,
      files: licenseFiles(dirname(p.manifest_path)),
    };
  });
}

function npmPackages() {
  const list = JSON.parse(execFileSync("npm", ["query", ".prod"], { cwd: ROOT, maxBuffer: 64 * 1024 * 1024 }).toString());
  return list
    .filter((p) => p.path !== ROOT)
    .map((p) => {
      const repo = typeof p.repository === "string" ? p.repository : p.repository?.url;
      return {
        eco: "npm package",
        name: p.name,
        version: p.version,
        license: typeof p.license === "string" ? p.license : p.license?.type ?? "UNKNOWN",
        url: (repo ?? `https://www.npmjs.com/package/${p.name}`).replace(/^git\+/, ""),
        files: licenseFiles(p.path),
      };
    });
}

// Standard texts for packages that only name their license. Short permissive licenses
// are templates (the copyright holders are the package authors — see each source URL);
// the long ones are taken verbatim from a package in the set that ships them.
const TEMPLATES = {
  MIT: `Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.`,
  "BSD-3-Clause": `Redistribution and use in source and binary forms, with or without modification, are
permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of
   conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list of
   conditions and the following disclaimer in the documentation and/or other materials
   provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors may be used
   to endorse or promote products derived from this software without specific prior
   written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.`,
  Zlib: `This software is provided 'as-is', without any express or implied warranty. In no event
will the authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following
restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you
   wrote the original software. If you use this software in a product, an acknowledgment
   in the product documentation would be appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be misrepresented
   as being the original software.
3. This notice may not be removed or altered from any source distribution.`,
};

/** Full Apache-2.0 / MPL-2.0 text from a package in the set that ships it verbatim. */
function verbatim(pkgs, marker) {
  for (const p of pkgs) for (const f of p.files) if (f.text.includes(marker) && f.text.length > 8000) return f.text;
  return null;
}

function build() {
  const pkgs = [...rustPackages(), ...npmPackages()];
  // One entry per name@version (the same crate can appear twice through two paths).
  const uniq = [...new Map(pkgs.map((p) => [`${p.eco}:${p.name}@${p.version}`, p])).values()].sort((a, b) =>
    a.name.localeCompare(b.name) || a.version.localeCompare(b.version, undefined, { numeric: true }),
  );
  const mpl = uniq.filter((p) => /MPL/.test(p.license) && !/OR Apache|Apache-2\.0 OR|OR MIT/.test(p.license));
  const head = [
    "Muya — third-party software notices",
    "=".repeat(36),
    "",
    "Muya includes the open-source software listed below. Each package is used under its",
    "own license, reproduced here. Generated by tools/third-party-notices.mjs — do not edit.",
    "",
    `Packages: ${uniq.length} (${uniq.filter((p) => p.eco === "Rust crate").length} Rust crates, ${uniq.filter((p) => p.eco === "npm package").length} npm packages)`,
    "",
  ];
  if (mpl.length) {
    head.push(
      "Mozilla Public License 2.0 components",
      "-------------------------------------",
      "The following components are covered by the MPL-2.0 and are used unmodified. Their",
      "source code is available at the addresses below:",
      ...mpl.map((p) => `  ${p.name} ${p.version} — ${p.url}`),
      "",
    );
  }
  const body = uniq.map((p) => {
    const lines = ["", "-".repeat(80), `${p.name} ${p.version}  (${p.eco})`, `License: ${p.license}`, `Source:  ${p.url}`, ""];
    if (!p.files.length)
      lines.push(`(The package ships no license file. It is licensed under ${p.license}; the standard text is in the appendix at the end, copyright by the package authors — see the source above.)`);
    for (const f of p.files) lines.push(`--- ${f.file} ---`, f.text, "");
    return lines.join("\n");
  });
  const texts = {
    ...TEMPLATES,
    "Apache-2.0": verbatim(uniq, "Apache License\n") ?? verbatim(uniq, "Apache License"),
    "MPL-2.0": verbatim(uniq, "Mozilla Public License Version 2.0"),
  };
  const appendix = ["", "=".repeat(80), "Appendix — standard license texts", "=".repeat(80)];
  for (const [id, t] of Object.entries(texts)) {
    if (!t) throw new Error(`no ${id} text found — add it to TEMPLATES`);
    appendix.push("", `--- ${id} ---`, t);
  }
  return head.join("\n") + body.join("\n") + appendix.join("\n") + "\n";
}

const text = build();
if (process.argv.includes("--check")) {
  const current = existsSync(OUT) ? readFileSync(OUT, "utf8") : "";
  if (current !== text) {
    console.error("THIRD_PARTY_LICENSES.txt is out of date — run: node tools/third-party-notices.mjs");
    process.exit(1);
  }
  console.log("THIRD_PARTY_LICENSES.txt is up to date");
} else {
  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, text);
  const missing = text.match(/ships no license file/g)?.length ?? 0;
  console.log(`wrote ${OUT} — ${(text.length / 1024).toFixed(0)} KB, ${missing} package(s) without a license file`);
}
