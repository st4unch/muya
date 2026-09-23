---
status: done
prd: docs/prd-opencode-support.md
started: 2026-09-23
finished: 2026-09-23
---

## Faz Çıktıları

Tek fazda uygulandı. Tüm AC'ler karşılandı.

**opencode kurulduktan sonra canlı doğrulandı (opencode 1.18.32):**

| Kontrol | Sonuç |
|---|---|
| `opencode_bin()` çözümleme + yetenek probu | ✅ `opencode` çözüldü, `session list --format json` yanıtladı |
| Gerçek oturumun ayrıştırılması | ✅ id / başlık (Türkçe) / zaman / dizin doğru |
| MCP kaydı (gerçek config'in kopyası) | ✅ mevcut `pencil` bozulmadan korundu, `muya-mcp` eklendi |
| `--auto` ve `--session` kabulü | ✅ hatalı bayrak yardım bastı, bizimkiler sessizce başladı |

Canlı testler `#[ignore]` ile repoda duruyor:
`cargo test --lib opencode::tests::live -- --ignored --nocapture`

**Canlı test bir HATA yakaladı — fixture'ların yakalayamayacağı türden:**
opencode'da pozisyonel argüman **proje dizini** (`opencode [project]` — "path to
start opencode in"), prompt değil. `buildAgentCommand` promptu Claude'daki gibi
pozisyonel geçiyordu, yani opencode onu dizin yolu sanardı ve oturum yanlış yerde
açılırdı — sessizce. Düzeltildi: opencode için prompt `--prompt` bayrağıyla gidiyor.

Gerçek çıktıda ayrıca beklemediğim bir `directory` alanı çıktı; oturum satırlarına
çalışma dizini — ve dolayısıyla git branch'i — olarak bağlandı.

## Değişiklikler

| Dosya | Ne değişti | AC |
|-------|-----------|-----|
| `src-tauri/src/opencode.rs` (yeni) | CLI çözümleme (yetenek probu), komut kurma, savunmacı oturum ayrıştırma | AC2, AC4 |
| `src-tauri/src/agents.rs` | `bin_via_login_shell` ortaklaştırıldı; `AgentSession.agent` alanı; `map_opencode`; liste birleştirme | AC7 |
| `src-tauri/src/fs.rs` | `install_opencode_mcp` (opencode şekli), `parse_opencode_mcps` (Resources listesi) | AC3 |
| `src-tauri/src/broker.rs` | `open_session` `agent` parametresi + `normalize_agent`; `register_mcp` ikisine birden yazıyor | AC5, AC6 |
| `src-tauri/src/bin/muya_ssh_mcp.rs` | `open_session` tool şeması + açıklaması | AC5 |
| `src/lib/agent.ts` | `detectAgent`, `AGENT_BASE_COMMAND`, `buildResumeCommand`, `tabAgent` | AC1, AC4 |
| `src/App.tsx` | `OpenTerminal.agent`; ajan türetme; open_session olayı; `launchAgent` genelleştirildi | AC1, AC5 |
| `src/components/NewAgentModal.tsx` | opencode preset'i; tip tablodan geliyor | AC9 |
| `src/components/SessionsPanel.tsx` | ajan başına ikon | AC8 |
| `src/components/SessionsPage.tsx` | ajan rozeti, ajana göre açma komutu, başlık | AC7 |
| `src/components/ResourcesPage.tsx` | opencode MCP rozeti | — |

## Kararlar

- **Bilinmeyen `agent` değeri hata, sessiz Claude'a düşüş değil.** opencode isteyip
  sessizce Claude alan bir ajan, sonraki mesajını yanlış türde oturuma gönderir ve
  bunu fark etmesinin yolu yoktur.
- **opencode oturum JSON'u savunmacı ayrıştırılıyor.** Şema yayınlanmamış ve
  opencode bu makinede kurulu değil; katı bir `Deserialize` yazmak, uydurulmuş bir
  sözleşmeyi doğrulanmış gibi sunmak olurdu. Hatanın bedeli eksik bir satır,
  asla bozuk bir liste.
- **`isClaude` korundu.** Türetilmiş alan olduğu için göç gerekmedi; `tabAgent()`
  eski sekmeleri düşürmeden okuyor.
- **opencode MCP'leri Claude'unkilerle dedupe EDİLMİYOR.** Aynı sunucunun iki
  kayıtta olması gerçekten iki kayıttır; hangisinin eksik olduğunu görmek
  operatörün ihtiyacı.

## Dersler

- opencode'un MCP biçimi diskte doğrulandı (`~/.config/opencode/opencode.json`)
  — dokümantasyona ek olarak gerçek dosya, `command` dizisini ve `type`/`enabled`
  alanlarını kesinleştirdi.
