---
status: done
prd: docs/prd-ssh-send.md
started: 2026-08-07
completed: 2026-08-07
---

## Faz Çıktıları
**P1 (2026-08-07) — opus impl:** 7/7 AC kod+unit. broker: SSH_SESSIONS issued-set (register/is_open/release) + handle_open sessionId üretir/emit eder/döner + handle_send (issued-set gate + audit log, içerik loglanmaz) + "send" op. lib.rs: ssh_release_session komutu. App.tsx: openSshServer explicitKey, ssh-broker-send → pty_write, closeTerminal → release. sidecar: ssh_send tool + ssh_open sessionId forward. Test: broker ssh_session_registration_gates_send. cargo 233 / tsc / npm 92 yeşil. Canlı GUI (agent ssh_open→ssh_send) operatör.

## Değişiklikler
| Tarih | Dosya | Ne değişti | AC |
|-------|-------|-----------|-----|
| 2026-08-07 | src-tauri/src/broker.rs | SSH_SESSIONS set + handle_open sessionId + handle_send + "send" op (+test) | AC1-5 |
| 2026-08-07 | src-tauri/src/lib.rs | ssh_release_session komutu + kayıt | AC5 |
| 2026-08-07 | src/App.tsx | openSshServer explicitKey, ssh-broker-send→pty_write, close→release | AC3,AC5 |
| 2026-08-07 | src-tauri/src/bin/muya_ssh_mcp.rs | ssh_send tool + schema + ssh_open sessionId forward | AC1,AC6 |

## Kararlar
- **Session-id = tab key:** broker `ssh:<serverId>:<nanos>` üretir, App bunu tab key olarak kullanır → id 1:1 PTY'ye maplenir; ayrı map gerekmez.
- **Fire-and-forget:** ssh_send çıktı döndürmez (insan ekranda görür); çıktı gereken agent ssh_run kullanır.
- **Audit:** sessionId + byte sayısı loglanır, metin İÇERİĞİ asla.

## Dersler
