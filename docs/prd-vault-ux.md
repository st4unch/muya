# Mini-PRD — Vault & Servers UX: gruplu kartlar, yerinde edit, tam genişlik

## 1. Amaç (ne işe yarar)
Password Store 14+ kayıtla düz bir liste — edit **en altta** açılıyor (kullanıcı kaydını kaybediyor), kayıtlar
gruplanamıyor, ve ekranın yalnız orta şeridi kullanılıyor (sağ/sol boş). Aynı sorun Servers sekmesinde de var.
Hedef: **gruplanabilir kartlar (expand/collapse) + yerinde (in-place) edit + tam genişlik**, Servers da aynı mantıkta.

## 2. Kapsam
- **Gruplama:** Credential ve Server'a serbest-metin `group` alanı (boş = "Ungrouped"). Add/Edit formunda
  girilir (mevcut grupların listesinden seçilebilir / yenisi yazılabilir).
- **Grup kartları:** her grup bir kart; başlıkta grup adı + kayıt sayısı; **expand/collapse** (durum
  localStorage'da kalıcı). Varsayılan: açık.
- **Yerinde edit:** düzenlenen kaydın satırı forma dönüşür (liste sonuna form açılmaz). İptal/kaydet satırda.
- **Tam genişlik:** `max-w-4xl` kalkar; grup içi kayıtlar responsive grid (geniş ekranda 2-3 kolon).
- **Servers sekmesi:** aynı grup-kart + expand/collapse + yerinde edit + tam genişlik.

## 3. Kapsam dışı
- Sürükle-bırak ile gruplama, iç içe gruplar, grup yeniden adlandırma toplu işlemi.
- Şifreleme/secret akışı değişikliği — `group` **secret değil**, düz metin alan (CredMeta'da da döner).

## 4. Kabul Kriterleri (binary)
- **AC1:** `Credential`/`CredMeta`/`CredInput` ve `Server` `group: String` (serde `default`) taşır; ESKİ store/config
  dosyaları (alan yok) hatasız yüklenir ve `group` "" olur. Unit test.
- **AC2:** Upsert `group`'u korur/günceller; store'a yazılıp okununca değer kalıcıdır. Unit test.
- **AC3:** Password Store kayıtları gruba göre kart-kart görünür; grup başlığında ad + adet; tıklayınca
  collapse/expand olur ve tercih yeniden açılışta hatırlanır.
- **AC4:** Bir kaydın kalem ikonuna basınca form **o satırın yerinde** açılır (listenin altında DEĞİL); iptal
  eski görünüme döner, kaydet listeyi tazeler.
- **AC5:** İçerik `max-w-4xl` ile sınırlı değil; geniş ekranda grup içi kayıtlar çok kolon.
- **AC6:** Servers sekmesi AC3-AC5'in aynısını yapar (gruplu kart, yerinde edit, tam genişlik).
- **AC7:** Grupsuz kayıtlar "Ungrouped" kartında toplanır; grup adı Türkçe karakter ve boşluk kabul eder.
- **AC8:** cargo + tsc + npm yeşil; mevcut store/server testleri kırılmaz.

## 5. Entegrasyon (harmony — dosya:satır)
- **Veri:** `credstore.rs` `Credential`(:48)/`CredMeta`(:66)/`CredInput`(:78) — `group` eklenir, `secret` yanına
  DEĞİL (CredMeta'da güvenle döner). `ssh.rs` `Server`(:~50) — `group` eklenir (`tags` dokunulmaz).
- **UI:** `src/components/SshPage.tsx` — `StoreTab`(:728) liste (:971-1005) grup-kart + inline edit'e dönüşür;
  `draft` state satır-bazlı olur (`draft.id === c.id` ise satır form). Servers tab aynı desene alınır.
  Sayfa sarmalayıcı `mx-auto max-w-4xl`(:142) → tam genişlik + padding.
- **Kalıcılık:** collapse durumu `localStorage["muya.vault.collapsed"]` (mevcut `apex.*` anahtar deseniyle uyumlu).
- **Koruma listesi:** unlock/lock akışı, secret reveal/copy/export, import SSH key, CyberArk sekmesi,
  `agent_access` toggle, MCP `list_secrets` alanları (group eklenir, mevcut alanlar aynı kalır).
