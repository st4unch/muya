# ADR 0001 — Grid View for up to 4 terminals (drag-drop, resize, layout, state)

Status: Accepted · Date: 2026-06-22 · Decider: software-architect

## Context
Tek panelde tab'lı terminaller var. Yeni "grid view": ≤4 terminal yan yana, drag-drop reorder,
panel resize. Kısıtlar (kod kanıtı):
- `src/components/Terminal.tsx:168-169` — her terminalde `ResizeObserver(syncSize)` zaten var;
  element kutusu değişince otomatik `fit.fit()` + `pty_resize`. Panel kütüphanesi sadece DOM
  kutusunu değiştirmeli, manuel resize trigger GEREKMEZ.
- `Terminal.tsx:184-191` — `active` prop ile hidden→visible'da rAF + re-fit.
- `App.tsx:1164-1173` — "tümü mount, sadece active `display`" pattern (Terax). Sessionlar tab
  geçişinde ölmez. Grid bunu bozmamalı.
- Bundle zaten büyük → en küçük ek ağırlık tercih.

## Decisions
1. **Drag-drop → `@dnd-kit/sortable`.** react-beautiful-dnd npm'de deprecated + repo arşivli
   (2025-08), React 19 belirsiz. dnd-kit topluluk konsensüsü, küçük, a11y, aktif bakım.
   HTML5 native ≤4 öğe için yeterli ama keyboard a11y + touch + sensor ekosistemi yok.
2. **Resize → `react-resizable-panels`.** Yüzde-tabanlı boyut (px değil) → ResizeObserver doğrulama
   gerektirmez, terminalin kendi RO'su fit'i halleder. allotment "tam VS Code görünümü" için;
   bize gerekmiyor + daha ağır. CSS fixed % drag-resize vermez. Nested `PanelGroup` ile 2x2.
3. **Layout → CSS Grid fixed columns (2x2), resize-edilebilir hücreler `react-resizable-panels`
   nested PanelGroup ile.** flex-wrap satır yüksekliğini deterministik vermez; grid `1fr 1fr /
   1fr 1fr` 4 terminal için kararlı. 1-3 terminalde grid-template adaptif.
4. **State → AYNI `openTerminals` (App.tsx:235).** Grid yalnız RENDER değişikliği; ayrı state
   crash/idempotency açısından çift kaynak-of-truth (drift riski) yaratır. `viewMode: 'tabs'|'grid'`
   + grid'de gösterilecek key listesi (`gridKeys`, ≤4) localStorage'a yazılır. Terminaller GENE
   hepsi mount kalır — grid'de görünenler `display:flex`, gerisi `display:none`. PTY hiç tear-down
   olmaz.

## Consequences
- (+) Tek state → reorder = `gridKeys` array mutasyonu, session korunur, resilience yüksek.
- (+) Sıfır manuel resize kodu — mevcut RO yeter (entegrasyon kanıtı: panel %-resize → element box
  değişir → RO → fit → pty_resize zinciri zaten test edilebilir).
- (-) Nested PanelGroup + dnd-kit overlay birlikte: drag sırasında pointer-events panel handle ile
  çakışabilir → drag handle'ı title bar'a izole et.
- İki yeni dependency (~ikisi de küçük, tree-shakeable).

## Rejected
- react-beautiful-dnd (deprecated/arşiv), HTML5 native (a11y/touch eksik), allotment (ağır, gereksiz),
  CSS fixed % (resize yok), ayrı grid state (drift/double-source riski).
