import { webkit } from "playwright";
const [svgfile, out, ...times] = process.argv.slice(2);
const b = await webkit.launch();
const p = await b.newPage({ viewport: { width: 520, height: 580 } });
await p.goto("file://" + svgfile);
await p.evaluate(() => { const s = document.documentElement; s.setAttribute("width", "520"); s.setAttribute("height", "580"); });
for (const [k, t] of times.entries()) {
  await p.evaluate((t) => { const ms = Number(t) * 1000; document.getAnimations().forEach((a) => { a.pause(); a.currentTime = ms; }); return ms; }, t);
  await p.screenshot({ path: `${out}_${String(k).padStart(2, "0")}.png` });
}
await b.close();
