# Step Output — Faz: faz-0-terminal-refactor

> Bu dosya append-only'dir. Her implementation/fix turu yeni bir `## Retry N` bloğu olarak eklenir.

---

## Retry 0

**Tarih:** 2026-06-30
**AC'ler:** AC-0-1, AC-0-2, AC-0-3, AC-0-4

### Kararlar
- `onBeforeSubmit` prop'u ref pattern ile sarıldı (`onBeforeSubmitRef`) — `useEffect([cwd])` closure'ı stale prop almaz.
- Keystroke buffer `keystrokeBufferRef` component seviyesinde `useRef<string>("")` olarak tanımlandı; `cwd` değişiminde sıfırlanır.
- Paste, `term.onData` üzerinden doğrudan PTY'ye iletildi — `attachCustomKeyEventHandler` yalnızca gerçek klavye event'lerine müdahale eder, bu sayede AC-0-3 sağlanır.
- `handleBeforeSubmit` App.tsx'e `useCallback` ile eklendi; prompt'u değiştirmeden döndüren Faz 0 stub'ı.
- `useCallback` import'u App.tsx'e eklendi.

### Değişen dosyalar
- `src/components/Terminal.tsx` — onBeforeSubmit prop + keystroke buffer + Enter intercept
- `src/App.tsx` — handleBeforeSubmit stub + prop geçişi

### Commit'ler
- `feat(prd): faz-0 AC-0-1 — onBeforeSubmit prop + Enter intercept + \x15 clear`
- `feat(prd): faz-0 AC-0-2 — Shift+Enter regresyon koruması (mevcut davranış korundu)`
- `feat(prd): faz-0 AC-0-3 — paste onBeforeSubmit tetiklemez (onData bypass)`
- `feat(prd): faz-0 AC-0-4 — keystroke buffer backspace + Ctrl+U temizleme`
