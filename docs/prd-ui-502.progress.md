---
status: active
---
# UI fixes 5.0.2 (branch fix/files-click) progress

Task: scratchpad/task-ui-fixes.md (FILES click, footer field menu, Settings width).

## Done (code + unit tests: 334 pass at last full run)
- FILES click: root cause = FileOutline only acted on double-click (files) and the triangle; root rows toggled on click. Now FileClickLogic (Sources/Logic) + FileOutline.onRowClick: file opens, folder toggles on single click. Verified in dev app (screenshots).
- Footer field menu: rebuilt in Appearance.swift (FieldRowView/FieldHeadingView/FieldListView, FieldPickerLayout). Verified dark.
- Settings: SettingsSizePlan (Sources/Logic/SettingsSizing.swift) + two columns in SettingsPalette.swift.

## In flight
- Settings two columns: columns were stretched to equal height (gap under Appearance). Just replaced the horizontal NSStackView with a plain host view + pinned columns; BUILT but NOT yet looked at. Re-run shots.
- Re-run ./build.sh test after that change.

## Left
- Retake all screenshots (/tmp/muya-ui502/shots.sh; stack: /tmp/muya-ui502/startstack.sh <bundle MacOS dir> <tag>, daemons must be copied into the app bundle and built with MUYA_PRODUCT_VERSION=5.0.2, restart stack after every build). Output: scratchpad/ui-502-shots/.
- Look at light-mode footer menu, filtered/nodata shots, settings 1120/1913/800.
- Repro FILES bug against 4.1.24 daemon (commit 5491805): NOT done.
- git-verify, then report to muya-all.
## Notes
- Dev stack from a Muya terminal needs launchd plists (ptyd gate); `open -n` for the app.

## Update (after quota came back)
- `./build.sh test` 334/0 with the two-column Settings; tests cover column widths (448 @960), 1120/1913/800/tiny plans and screen clamps (Tests/SettingsSizingTests.swift).
- 4.1.24 repro DONE, by debug-socket assertions (no screenshots): hooks `uf-click-row <path>` + `uf-tree-state`; script /tmp/muya-ui502/assert.sh <daemon-bin-dir> <tag> (scratchpad copy only). With the branch daemons AND daemons built from 5491805 (scratchpad/wt-old) the result is identical: click folder -> expanded set gains `src`, rows 4->5; click file -> viewer=lib.rs; section stays `open`. So the FILES bug never depended on the old daemon: the cause was the app's click handling (old code only acted on triangle/double-click).
- CHANGELOG [5.0.2] has the three lines.

## Screenshots still owed (need an unlocked screen)
Run: `/tmp/muya-ui502/shots.sh` (needs the stack: `/tmp/muya-ui502/startstack.sh <app>/Contents/MacOS <tag>` after copying target/debug/muyad + muya-ptyd, built with MUYA_PRODUCT_VERSION=5.0.2, into the bundle; restart stack after every ./build.sh). Writes scratchpad/ui-502-shots/*.png. LOOK at: settings-1120/1913/800 dark+light (check no gap under Appearance), footer-menu* light, files-expanded/folder-opened/file-opened dark+light (sessions must exist).

## Where I stopped (Settings resize + popover anchor)
- Changed: SettingsSizePlan now grows with the window (1..3 columns, width up to 1528, height up to 94% of host/screen, `splitCounts` for balanced columns); SettingsController.fitHeight picks the fewest columns that need no vertical scroll; arrange() has left/mid/right columns; footer popover slides left to stay inside the window (Appearance.swift show(from:rect:)); debug hooks `uf-settings` (prints "w h columns scrolls=") and `uf-fields-id`.
- Measured via debug socket: 1913x1000 -> 3 columns, 1528x902, scrolls=false. 1120x700 -> 2 columns 1024x658, scrolls=true (cannot fit). 800x600 -> 1 column, scrolls=true (expected).
- Tests 334/0 at last run. Screenshots NOT retaken after this change; footer popover anchoring NOT looked at; root-row purple outline + "view" badge NOT investigated (it is the "marked active root" drawing in FileTree.swift, probably intentional; compare with classic).
- Next: restart stack (startstack.sh, daemons copied into the bundle after each build), run /tmp/muya-ui502/shots.sh, LOOK at settings-1120/1913/800 both themes and footer-menu-*, then report.
