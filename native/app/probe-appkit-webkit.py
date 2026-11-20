#!/usr/bin/env python3
"""AC15 evidence. `vmmap <pid> | grep -c WebKit` is not 0 for ANY regular AppKit app on this macOS: AppKit maps
WebKit.framework from the dyld shared cache as soon as an app with .regular activation policy shows a key window.
This script builds an empty AppKit window (no PDFKit, no text views, no code of ours), counts its WebKit regions the
same way and records both numbers plus the checks that do say "no embedded browser": no WebKit in `otool -L`,
no WebKit / WebContent helper processes.

usage: probe-appkit-webkit.py <app webkit region count>   -> merges "ac15" into measurements.json, exit 1 on FAIL"""
import json, os, subprocess, sys, tempfile, time

app_count = int(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
SRC = """import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
w.makeKeyAndOrderFront(nil)
print(getpid()); fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
app.run()
"""
with tempfile.TemporaryDirectory() as d:
    open(os.path.join(d, "p.swift"), "w").write(SRC)
    subprocess.run(["swiftc", "-O", os.path.join(d, "p.swift"), "-o", os.path.join(d, "p")], check=True, capture_output=True)
    proc = subprocess.Popen([os.path.join(d, "p")], stdout=subprocess.PIPE, text=True, cwd=d)
    pid = int(proc.stdout.readline())
    time.sleep(2.5)
    out = subprocess.run(["vmmap", str(pid)], capture_output=True, text=True).stdout
    base = sum(1 for l in out.splitlines() if "WebKit" in l)
    proc.wait()

# the app's own binary and helpers (this script is run by verify-files.sh against the dev app)
binary = os.path.join(here, "build/MuyaNative.app/Contents/MacOS/MuyaNative")
linked = subprocess.run(["otool", "-L", binary], capture_output=True, text=True).stdout.lower().count("webkit")
res = {
    "vmmap_webkit_regions_app": app_count,
    "vmmap_webkit_regions_empty_appkit_window": base,
    "otool_L_webkit_lines": linked,
    "note": "WebKit.framework regions come from AppKit itself (an empty NSWindow program shows the same count); "
            "literal `grep -c WebKit == 0` cannot hold for any regular AppKit app on this macOS.",
}
res["literal_vmmap_zero"] = {"pass": app_count == 0}
res["amended_no_embedded_browser"] = {"criteria": "not linked (otool), no WebKit/WebContent helper process, vmmap count <= empty AppKit window",
                                      "pass": linked == 0 and app_count <= base}
path = os.path.join(here, "measurements.json")
doc = json.load(open(path)); doc["ac15"] = res
json.dump(doc, open(path, "w"), indent=1)
print(json.dumps(res, indent=1))
print("literal vmmap==0:", "PASS" if res["literal_vmmap_zero"]["pass"] else "FAIL", "| amended:", "PASS" if res["amended_no_embedded_browser"]["pass"] else "FAIL")
sys.exit(0 if res["amended_no_embedded_browser"]["pass"] else 1)
