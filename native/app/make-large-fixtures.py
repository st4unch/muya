#!/usr/bin/env python3
# Created by Claude — Classification: INTERNAL
# Realistic large text fixtures for the viewer/editor measurements (docs/prd-large-file-open.md).
# usage: make-large-fixtures.py <dir> <kind: json|log|ts|minjs|md> <MB>   -> <dir>/big-<kind>-<MB>mb.<ext>
import json, random, sys, os
d, kind, mb = sys.argv[1], sys.argv[2], float(sys.argv[3])
want = int(mb * 1024 * 1024)
ext = {"json": "json", "log": "log", "ts": "ts", "minjs": "js", "md": "md"}[kind]
os.makedirs(d, exist_ok=True)
path = os.path.join(d, f"big-{kind}-{sys.argv[3]}mb.{ext}")
r = random.Random(42)
n = 0; i = 0
with open(path, "w") as f:
    if kind == "json":
        f.write("[\n"); n = 2
    while n < want:
        if kind == "json":
            rec = json.dumps({"id": i, "uuid": f"u-{r.randrange(10**9)}-{i}", "name": f"item {i}", "active": r.random() > .5, "score": round(r.random() * 100, 3), "tags": ["alpha", "beta", f"t{i % 17}"], "nested": {"a": i * 2, "b": f"value {i % 91}", "c": [1, 2, 3]}}, indent=2)
            s = (",\n" if i else "") + "\n".join("  " + l for l in rec.split("\n"))
        elif kind == "log":
            s = f"2026-11-13T10:{(i // 60) % 60:02d}:{i % 60:02d}.{r.randrange(1000):03d}Z {r.choice(['INFO','WARN','ERROR','DEBUG'])} svc.worker[{r.randrange(64)}] request id={r.randrange(10**9)} path=/api/v1/items/{i} status={200 + r.randrange(5)} took={r.randrange(900)}ms\n"
        elif kind == "ts":
            s = f"export interface Thing{i} {{\n  id: number;\n  name: string;\n  tags: string[];\n}}\n\nexport function build{i}(input: Partial<Thing{i}> = {{}}): Thing{i} {{\n  // Build a thing with sensible defaults; keep the signature stable.\n  const base: Thing{i} = {{ id: {i}, name: \"thing-{i}\", tags: [\"a\", \"b\"] }};\n  return {{ ...base, ...input }};\n}}\n\n"
        elif kind == "minjs":
            s = f"function f{i}(a,b){{var c=a+b*{i};return c>{i}?c-{i}:\"s{i}\"}}var v{i}=f{i}({i},2);"
        else:
            s = f"## Section {i}\n\nSome *emphasis* and **bold** text with a [link](https://example.com/{i}) and `code {i}`.\n\n- item one\n- item two {i}\n- item three\n\n```ts\nconst x{i} = {i};\n```\n\n"
        f.write(s); n += len(s); i += 1
    if kind == "json": f.write("\n]\n")
print(path)
