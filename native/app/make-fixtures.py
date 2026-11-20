#!/usr/bin/env python3
"""Fixture folder for verify-files.sh: a git repo with an ignored folder and ignored log files, a PNG, a PDF,
a Markdown document, source / plain text, a binary file, a hidden file and nested folders.
usage: make-fixtures.py <dir>   (an existing dir inside a muya-dev.* temp dir is replaced)"""
import os, shutil, struct, subprocess, sys, zlib

root = sys.argv[1]
if os.path.isdir(root) and "muya-dev." in root:  # only ever inside a throwaway dev dir
    shutil.rmtree(root)
os.makedirs(root, exist_ok=True)


def w(rel, data, mode="w"):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, mode) as f:
        f.write(data)


# PNG: 320x200 diagonal gradient with a white frame
W, H = 320, 200
raw = b""
for y in range(H):
    raw += b"\x00"
    for x in range(W):
        edge = x < 4 or y < 4 or x >= W - 4 or y >= H - 4
        raw += bytes((255, 255, 255) if edge else (int(255 * x / W), int(255 * y / H), 180))


def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
w("assets/gradient.png", png, "wb")

# PDF: two pages of text, Helvetica
def pdf(pages):
    objs = []
    objs.append("<< /Type /Catalog /Pages 2 0 R >>")
    kids = " ".join(f"{3 + 2 * i} 0 R" for i in range(len(pages)))
    objs.append(f"<< /Type /Pages /Kids [{kids}] /Count {len(pages)} >>")
    for i, lines in enumerate(pages):
        n = 3 + 2 * i
        stream = "BT /F1 22 Tf 72 720 Td 28 TL " + " ".join(f"({l}) Tj T*" for l in lines) + " ET"
        objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {n + 1} 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> >>")
        objs.append(f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream")
    out = b"%PDF-1.4\n"
    offs = []
    for i, o in enumerate(objs):
        offs.append(len(out))
        out += f"{i + 1} 0 obj\n{o}\nendobj\n".encode()
    x = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    for o in offs:
        out += f"{o:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n".encode()
    return out


w("docs/report.pdf", pdf([["Quarterly report", "Page one of two", "Rendered by PDFKit"], ["Second page", "No WebKit involved"]]), "wb")

w("docs/notes.md", """# Muya Native

A short **status** note with *emphasis*, `inline code` and a [link](https://example.com).

## What works

- File tree with lazy loading
- FSEvents watcher, under one second
  - nested bullet
- Native viewers

1. Images in NSImageView
2. PDF in PDFKit
3. Markdown, rendered natively

### Code

```swift
let tree = FileTreePanel()
tree.setRoot("/tmp")
```

> The text viewer is read-only for now.

---

Last paragraph, with a ~~strike~~ and **bold *nested* text**.
""")
w("src/main.rs", 'fn main() {\n    println!("hello from the text viewer");\n    // read-only preview\n}\n')
w("src/lib.rs", "pub fn add(a: i32, b: i32) -> i32 { a + b }\n")
w("README.txt", "Plain text file.\nSecond line with ş ğ 日本語.\n")
w("data/blob.bin", bytes(range(256)) * 4, "wb")
w(".env.example", "TOKEN=changeme\n")
w(".gitignore", "build/\n*.log\n")
w("build/output.o", "x")
w("debug.log", "ignored\n")
w("zeta/inner/deep.txt", "deep\n")
env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
subprocess.run(["git", "init", "-q", root], check=True, env=env)
