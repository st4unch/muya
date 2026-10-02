---
status: done
prd: docs/prd-workspace-scope.md
started: 2026-10-02
---

## Faz Çıktıları

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-10-02 | src/lib/workspaceScope.ts (+test) | Üyelik kuralı: klasör altı, `<repo>-worktrees`, SSH her yerde | AC1, AC7 |
| 2026-10-02 | src/App.tsx | Liste süzme, menüde All + sayaçlar, seçim workspace'i takip eder, All kalıcı | AC1–AC6 |

## Kararlar
- Scope = mevcut `selectedRoot`; yeni state yok. Üyelik spawn cwd'den türetilir (tab'a alan eklenmez, kalıcı veri göçü yok).
- SSH sekmeleri her workspace'te görünür (yerel klasöre bağlı değiller).

- 2026-10-02 operatör değişikliği: workspace yalnız elle değişir (üst menü + dosya ağacı kökünde sağ tık "Select workspace"). Otomatik takip (palet/zil/MCP) kaldırıldı; palet, zil ve Grid de seçili workspace'e süzülür; Grid başlığına workspace düğmesi eklendi. Başka workspace'te açılan oturum arka planda kendi workspace'inde açılır, görünüm değişmez.

## Doğrulama
- (2. tur) WebKit: kök klasöre düz tık workspace'i değiştirmedi; sağ tık → Select workspace iptv'ye geçirdi (liste 1); palet yalnız iptv-2a; Grid ccp=3 panel, iptv=1 panel, 7 xterm canlı.
- vitest 350/350, tsc temiz. WebKit akışı: ccp=3, iptv=1, ccp'den ⌘K ile iptv agent → başlık iptv'ye geçti; All=7; 7 xterm her geçişte canlı; ⌘T numbat'ta açıldı; All → localStorage anahtarı silindi.
- Mock her yüklemede selectedRoot'u yeniden yazdığı için reload sonrası kalıcılık localStorage üzerinden doğrulandı.

## Dersler
