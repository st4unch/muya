// Created by Claude — Classification: INTERNAL
//
// Serve the SAME font files to the reference HTML and to the app.
//
// The references pull IBM Plex Sans / JetBrains Mono from Google Fonts; the app
// bundles them from @fontsource. Two different font files would put a glyph-level
// difference into every pixel diff and hide real layout differences. So the
// Google Fonts request is answered from the fontsource files the app ships.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const FAKE_ORIGIN = "https://fonts.redesign.local";

const FAMILIES = [
  { pkg: "@fontsource/ibm-plex-sans", weights: [400, 500, 600] },
  { pkg: "@fontsource/jetbrains-mono", weights: [400, 500, 700] },
];

/** One stylesheet with every @font-face the app uses, font URLs on FAKE_ORIGIN. */
export function fontCss() {
  let css = "";
  for (const { pkg, weights } of FAMILIES) {
    for (const w of weights) {
      const file = readFileSync(join(root, "node_modules", pkg, `${w}.css`), "utf8");
      css += file.replace(/url\(\.\/files\/([^)]+)\)/g, `url(${FAKE_ORIGIN}/${pkg}/$1)`);
    }
  }
  return css;
}

/** Route Google Fonts + the fake origin to the local fontsource files. */
export async function routeFonts(page) {
  const css = fontCss();
  await page.route("https://fonts.googleapis.com/**", (r) =>
    r.fulfill({ contentType: "text/css", body: css }),
  );
  await page.route(`${FAKE_ORIGIN}/**`, (r) => {
    const rel = new URL(r.request().url()).pathname.slice(1); // "@fontsource/x/file.woff2"
    const [scope, name, ...rest] = rel.split("/");
    const body = readFileSync(join(root, "node_modules", scope, name, "files", ...rest));
    return r.fulfill({ contentType: "font/woff2", body });
  });
}
