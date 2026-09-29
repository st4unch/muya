// Created by Claude — Classification: INTERNAL
//
// The UI is ENGLISH. The reference designs were drawn with Turkish copy; this table
// is the single source for every visible string of the redesigned screens.
// `make-en-references.mjs` applies it to the reference HTML so the pixel diff
// compares the app against the SAME design with the English copy.
//
// Order matters: longer phrases first so a shorter one never eats part of them.

export const STRINGS = [
  // header
  ["Agent, dosya veya komut ara…", "Search agents, files or commands…"],
  ['aria-label="Bildirimler"', 'aria-label="Notifications"'],
  // rail
  ['aria-label="Ana gezinme"', 'aria-label="Main navigation"'],
  [">Kaynak</button>", ">Resources</button>"],
  ['aria-label="Ayarlar"', 'aria-label="Settings"'],
  // agent list
  ['aria-label="Agentlar"', 'aria-label="Agents"'],
  [">Agentlar <span", ">Agents <span"],
  ["+ Yeni agent", "+ New agent"],
  [">Tümü<", ">All<"],
  [">Bekleyen 1<", ">Waiting 1<"],
  [">Çalışan 2<", ">Working 2<"],
  ["SENİ BEKLİYOR", "WAITING FOR YOU"],
  [">ÇALIŞIYOR<", ">WORKING<"],
  [">BOŞTA<", ">IDLE<"],
  ["İzin istiyor: fs_write_file", "Needs permission: fs_write_file"],
  ["Unfurling… · 16.9k token<", "Unfurling… · 16.9k tokens<"],
  ["[son aktivite satırı]", "[last activity line]"],
  ["Sürükle-bırak ile sırala", "Drag to reorder"],
  // session header
  ["Bypass permissions açık", "Bypass permissions on"],
  ["Grid'e böl", "Split to grid"],
  [">Durdur <span", ">Stop <span"],
  ['aria-label="Diğer işlemler"', 'aria-label="More actions"'],
  // progress strip
  ["4m 15s · ↓ 16.9k token · 3s düşündü", "4m 15s · ↓ 16.9k tokens · thought for 3s"],
  ["Güncelleme hazır", "Update ready"],
  ["Yeniden başlat", "Restart"],
  // composer
  ["muya-all'a mesaj", "Message muya-all"],
  ["muya-all'a yaz… ( / komut, @ dosya )", "Message muya-all… ( / commands, @ files )"],
  ["Mod: bypass ▾", "Mode: bypass ▾"],
  ["@ Dosya ekle", "@ Add file"],
  ["/ Komutlar", "/ Commands"],
  ["⏎ gönder · ⇧⏎ satır", "⏎ send · ⇧⏎ newline"],
  ['aria-label="Gönder"', 'aria-label="Send"'],
  // inspector
  ["ONAY BEKLİYOR", "NEEDS APPROVAL"],
  ["</span> dosya yazmak istiyor", "</span> wants to write a file"],
  [">İzin ver <span", ">Allow <span"],
  [">İzin ver<", ">Allow<"],
  [">Reddet <span", ">Deny <span"],
  [">Reddet<", ">Deny<"],
  [">Aç<", ">Open<"],
  ["Değişiklikler <span", "Changes <span"],
  [">Dosyalar<", ">Files<"],
  [">Aktivite<", ">Activity<"],
  ["+ 11 dosya daha", "+ 11 more files"],
  ["Diff'i incele", "Review diff"],
  ["Dosya çakışması yok", "No file conflicts"],
  ["3 worktree izleniyor · 14 değişiklik", "3 worktrees watched · 14 changes"],
  // footer
  [">Hazır</span>", ">Ready</span>"],
  [">3 workspace<", ">3 workspaces<"],
  ["7 agent · <span", "7 agents · <span"],
  ["2 çalışıyor</span>", "2 working</span>"],
  ["1 bekliyor</span>", "1 waiting</span>"],
  ["0 çakışma", "0 conflicts"],
  ["Tab ile paneller arası · ⌘⏎ büyüt", "Tab to switch panels · ⌘⏎ maximize"],
  // grid
  [">4 panel<", ">4 panels<"],
  ['aria-label="Düzen"', 'aria-label="Layout"'],
  ["Bekleyenleri öne al", "Waiting first"],
  ["Hepsine yayınla…", "Broadcast to all…"],
  ["İzin bekliyor · 1 dk", "Needs permission · 1m"],
  ['aria-label="Büyüt"', 'aria-label="Maximize"'],
  ["Bu oturumda hep izin ver", "Always allow this session"],
  ["Çalışıyor · [süre]", "Working · [duration]"],
  ["Çalışıyor · 4m 15s", "Working · 4m 15s"],
  ["muya-all'a yaz…", "Message muya-all…"],
  ["opencode-review'a yaz…", "Message opencode-review…"],
  [">Boşta<", ">Idle<"],
  ["Görev bekliyor", "Waiting for a task"],
  ["Queue'dan görev ata", "Assign from Queue"],
  ["Paneli değiştir", "Swap panel"],
  // shared leftovers (must come after the longer phrases above)
  [">1 dk<", ">1m<"],
  ["[süre]", "[duration]"],
  ['lang="tr"', 'lang="en"'],
];

/** Strings the redesign adds beyond the references (operator-approved extras). */
export const EXTRA = {
  closeFile: "Close",
  themeLabel: { system: "Theme: system", light: "Theme: light", dark: "Theme: dark" },
  statusWaiting: "Waiting",
  statusIdle: "Idle",
  broadcastTitle: "Broadcast to all panels",
};

export function translate(html) {
  let out = html;
  for (const [tr, en] of STRINGS) out = out.split(tr).join(en);
  return out;
}
