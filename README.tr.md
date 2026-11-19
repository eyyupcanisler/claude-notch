# ClaudeNotch

[English](README.md) · **Türkçe**

![ClaudeNotch demo](docs/demo.gif)

MacBook çentiğinde (notch) yaşayan, menü çubuğunda ikonu olmayan (`LSUIElement`) bir macOS
uygulaması. Claude Code oturumlarının durumunu gösterir (çalışıyor / bitti / girdi bekliyor /
hata) ve terminalde olmasanız bile izin isteklerini çentikten **İzin ver / Her zaman / Reddet**
ile yanıtlamanızı sağlar. Arayüz Mac'in diline uyar: Mac'in ilk dili Türkçeyse Türkçe, değilse
İngilizce. Ayarlar > Genel > Dil'den Türkçe ya da English seçilebilir (yeniden başlatınca geçerli
olur).

## Nasıl çalışır

```
Claude Code ──hook──> hooks/claude-notch-hook.sh ──curl──> Unix soketi ──> ClaudeNotch.app
                                                    ~/Library/Application Support/ClaudeNotch/notch.sock
```

- Soket dizini `0700`, soket dosyası `0600`. TCP portu **yoktur**.
- `PermissionRequest` hook'u terminaldeki izin penceresiyle **eş zamanlı** çalışır. Çentikten
  yanıt verirseniz pencere kapanır ve araç çalışır; terminalde yanıtlarsanız kart, ilgili
  `PostToolUse` olayıyla (yaklaşık 1-2 sn içinde) otomatik kaybolur.
- Uygulama kapalıysa ya da soket yoksa hook sessizce çıkar (çıktı yok, `exit 0`); terminaldeki
  normal izin akışı etkilenmez. Köprü hiçbir zaman varsayılan olarak "izin ver" demez.

## Google Takvim (doğrudan bağlantı)

ClaudeNotch Google'a kendi OAuth istemcinle bağlanır (yalnız okuma). Bir kez:

1. <https://console.cloud.google.com> → yeni bir proje (ör. "ClaudeNotch").
2. **APIs & Services → Library** → "Google Calendar API" → **Enable**.
3. **APIs & Services → OAuth consent screen** (Google Auth Platform):
   - Google Workspace hesabıysan **Internal** seç: doğrulama gerekmez, oturum kalıcıdır.
   - Kişisel Gmail ise **External** + kendini **Test users**'a ekle. "Testing" durumunda
     Google oturumu 7 günde bir sona erdirir; kalıcı olsun istersen yayın durumunu
     "In production" yap (doğrulanmamış uygulama uyarısını bir kez geçmen gerekir).
   - Scope: `.../auth/calendar.readonly`.
4. **Credentials → Create credentials → OAuth client ID → Application type: Desktop app**
   → oluştur → **Download JSON** (`client_secret_….json`).
5. ClaudeNotch Ayarları → Modüller → Takvim → Kaynak: **Google Takvim** → **İstemci
   dosyasını seç…** → indirdiğin JSON → **Google ile bağlan** → tarayıcıda izin ver.

İstemci bilgisi ve jetonlar yalnız senin okuyabildiğin bir dosyada tutulur
(`~/Library/Application Support/ClaudeNotch/google.json`, `0600`); JSON dosyasını depoya koyma. Toplantının Meet / Zoom
bağlantısı varsa paneldeki takvim kartı başlangıçtan 15 dk önce **Katıl** düğmesi gösterir
(çentiğin yanındaki kanatlar yalnızca hatırlatır; tıklamak paneli açar).

## İndirerek kurma (en kolayı)

1. [Son sürümden](https://github.com/eyyupcanisler/claude-notch/releases/latest)
   `ClaudeNotch-<sürüm>.zip` dosyasını indir, aç ve **ClaudeNotch.app**'i **Uygulamalar**
   klasörüne taşı.
2. Aç. Uygulama Apple Developer ID ile imzalı olmadığı için macOS ilk açılışı engeller:
   **Sistem Ayarları → Gizlilik ve Güvenlik → Yine de Aç**. (Ya da Terminal'de:
   `xattr -dr com.apple.quarantine /Applications/ClaudeNotch.app`.)
3. Spotlight'tan **ClaudeNotch**'ı tekrar açınca Ayarlar gelir:
   **Genel → Claude Code bağlantısı → Kancaları kur**. Kancalar `~/.claude/settings.json`
   dosyasına yedek alınarak eklenir, diğer ayarlarına dokunulmaz.

Gereksinim: macOS 14+ (macOS 14'te `brew install jq`; macOS 15 ve sonrasında hazır gelir) ve
Claude Code.

## Derleme

```sh
scripts/make-signing-identity.sh  # bir kez: kendi anahtar zincirine "ClaudeNotch Dev"
scripts/build-app.sh              # build.noindex/ClaudeNotch.app üretir (release)
scripts/install-app.sh            # ~/Applications'a kopyalar ve başlatır
swift test                        # birim testleri
```

- Uygulamanın Dock simgesi ve penceresi yoktur; arayüzü çentiktir. Çalışırken Spotlight'tan
  (ya da Finder/Launchpad'den) yeniden açmak **Ayarlar**'ı getirir. Ayarlar'a ayrıca panel
  bandındaki dişliden ve çentiğe sağ tıklayarak da ulaşılır.

- `make-signing-identity.sh` kimliği oturum açma anahtar zincirine değil, ayrı bir anahtar
  zincirine koyar: `~/Library/Keychains/claude-notch-signing.keychain-db` (rastgele parolası
  `~/Library/Application Support/ClaudeNotch/signing-keychain.pass`, izin 0600). Parolayı
  bildiği için codesign erişimini (`set-key-partition-list`) penceresiz ayarlar; oturum açma
  parolası gerekmez. Tekrar çalıştırılabilir; güven ayarı eklemez.
- `build-app.sh`, `CLAUDE_NOTCH_SIGN_ID` (varsayılan `ClaudeNotch Dev`) kimliğiyle bu anahtar
  zincirinden imzalar (zinciri yalnızca imza süresince arama listesine ekler, sonra listeyi
  geri yükler); o zincir yoksa aynı adlı başka bir kimliği, o da yoksa ad-hoc imzayı dener.
  Kalıcı kimlikle tasarım gereksinimi `certificate leaf = H"…"` olur (cdhash değil); bu yüzden
  Otomasyon izni (ClaudeNotch → Ghostty) bir kez verilince yeniden derlemelerde korunur.
  Ad-hoc imzada her derlemeden sonra izin yeniden istenir.

Gereksinimler: macOS 14+, Swift 6 araç zinciri, `jq` ve `curl`.

## Hook kurulumu

En kolayı uygulamanın içinden: **Ayarlar → Genel → Claude Code bağlantısı → Kancaları kur**.
Uygulama içindeki köprü betiğini `~/Library/Application Support/ClaudeNotch/` altına kopyalar ve
kancaları ona bağlar (uygulama taşınsa ya da güncellense de yol değişmez). Kaynak koddan:

```sh
scripts/install-hooks.sh                       # ~/.claude/settings.json içine ekler
scripts/install-hooks.sh --print               # yazmadan hook JSON'unu gösterir
scripts/install-hooks.sh --settings ./test.json  # başka bir ayar dosyasını hedefler
scripts/install-hooks.sh --uninstall           # ClaudeNotch hook'larını kaldırır
scripts/install-hooks.sh --hook <yol>          # kancaların çağıracağı köprü betiği
```

- Yazmadan önce `settings.json.bak.<zaman damgası>.<rastgele>` yedeği alınır, diğer tüm anahtarlar korunur.
- Betik tekrar çalıştırılabilir (idempotent): önceki ClaudeNotch kayıtları silinip yeniden eklenir.
- Kaydedilen hook'lar: `PermissionRequest` (bloklayan, 600 sn), `PreToolUse` +
  `AskUserQuestion` eşleşmesi (soruyu çentikte bekletir, 600 sn) ve async olay hook'ları
  `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Stop`,
  `StopFailure`, `Notification`, `SessionEnd`.
- Hook betiğinin yolu mutlaktır; proje klasörünü taşırsanız kurulumu yeniden çalıştırın.

## Kullanım

- **Kapalı:** oturum yoksa yalnızca donanım çentiği görünür, hiçbir şey çizilmez. Oturum varsa
  çentiğin hemen altında (2 pt boşluk) ortalı, 3 pt'lik bir **durum çizgisi** belirir: çentik
  genişliğinin iki yanından 24 pt içeride, oturum başına bir parça (en çok 6, sabit sırada).
  Renk yalnızca "sizi bekliyor" anlamına gelir. Düz gri ışıltı: çalışıyor; amber nefes: sizi
  bekliyor (izin / soru / plan / girdi); mavi: görülmemiş "bitti" (bakmanız gereken sohbet) (gelişte
  bir kez parlar); kırmızı: hata; soluk beyaz: boşta. Hareketi
  azalt açıkken renkler durağandır. Çizgi menü çubuğu bandına hiç taşmaz; bandın çentik
  dışındaki kısmında tıklamalar her zaman arkadaki menülere gider.
  Ayarlar > Genel > Görünüm > Durum renkleri > **Renk körlüğüne uygun** seçilirse renkler hemen
  kırmızı-yeşil renk körlüğünde de ayrışanlara döner ve her duruma bir biçim işareti eklenir:
  gri `#8E8E8E` kayan ışıltı = çalışıyor, sarı `#F0E442` yavaş nefes = sizi bekliyor, mavi
  `#388BFD` = bitti (bakmanız gereken sohbet), kesik (üç kısa çizgi) pembe-kırmızı `#FB7185` = hata, soluk beyaz = boşta.
  İki paletle de renk sizin için bir şey demektir: sizi bekliyor, hata ya da bakmanız gereken biten sohbet.
- **Kanatlar (aşağı düşen ada yok):** izin, soru / plan / bekleme, bitti, hata ve modül
  notları artık menü çubuğu bandının altına inmez; altındaki Chrome sekmeleri tıklanabilir
  kalır. Çentik bandla aynı yükseklikte **yana doğru** büyür. İlk 4 sn sol kanat renkli bir
  işaret ve kısa özet, proje ve terminal sekmesinin adıyla ("claude-notch · Testleri düzelt
  çalıştırmak istiyor"), sağ kanat tek satır ayrıntı (komut, sorunun ilk sözcükleri) gösterir;
  kanat görünürken o sohbetin durum çizgisindeki parçası yanar (biraz daha kalın ve parlak);
  sonra kanatlar küçük bir renkli işarete (sol nokta,
  sağda kalkan / ? / ! / onay işareti; birden çok bekleyen varsa sayı) daralır. Yalnızca
  Claude’u bekleten şeylerin işareti kalır: izin, soru, plan ve bekleme işareti siz ilgilenene
  kadar durur; bitti, hata ve modül notlarında işaret kalmaz (durum çizgisi onları gösterir).
  Odak açıkken yalnızca bekleten şeyler görünür, o da yalnızca işaret olarak (aşağıda
  Rahatsız Etme'ye bakın). Kanatlara tıklamak paneli
  açar (yalnızca terminalde yanıtlanan soru, o terminal sekmesine götürür); çentiğin üzerine
  gelmek paneli eskisi gibi açar (Ayarlar > Genel > Görünüm > **Üzerine gelince paneli aç**;
  kapalıyken çentik imleç altında yalnızca hafifçe büyür, panel tıklayınca açılır). Ayarlar > Bildirimler > **Çentiğin yanında yalnızca küçük
  bir işaret göster** (varsayılan: kapalı; Genel > Görünüm altında da var) 4 sn'lik metni hiç
  göstermez ve işareti hemen çıkarır. Çentiksiz harici ekranlarda aynısı hap şeklinin iki
  yanında olur.
- **Panel:** yalnızca siz açtığınızda: çentik ya da çizgi üzerinde ~300 ms beklemek (hızlı
  geçişler yok sayılır), çentiğe tıklamak ya da ⌃⌥Space. 600 pt genişliğinde, ortalıdır ve açık
  kaldığı sürece kendi genişliği boyunca menü çubuğu bandını alır: çentiğin solunda iğne
  (sabitle), dişli (ayarlar) ve Ghostty izni eksikse kilit simgesi; sağında "N izin" ve
  "N çalışıyor" çipleri. Gövde gerçek buzlu cam (Saydamlığı azalt açıkken düz koyu); kartlar
  ve satırlar düz, yükseltilmiş bir katmandadır. İmleç çıkınca kapanır (sabitliyse ya da
  klavyeyle açıldıysa kapanmaz).
- **Liste ve kartlar:** sıra sabittir (sizi bekleyenler, bitenler, çalışanlar, sessiz, boşta) ve
  imleç paneldeyken değişmez; "Kartı göster" bir satırı karta taşıyınca karttan çıkan oturum
  onun yerine geçer, diğer satırlar kıpırdamaz. Birden çok kart 1/N sayfalayıcıyla gezilir.
  Reddet solda, İzin ver sağda, "Her zaman" ⋯ altında kuralıyla. Riskli komutlarda (rm -rf,
  sudo, curl | sh, chmod -R, git push --force, > /dev/…; ayrıca veri sızdırma biçimleri: curl /
  wget ile dosya gönderme `-d @dosya`, `--data-binary @`, `-F x=@`, `-T`, `--upload-file`,
  `--post-file`; uzak sunucuya scp / rsync / sftp; nc / ncat; ~/.ssh, ~/.aws, .env, *.pem,
  *.key içeriğinin bir yere aktarılması) İzin ver basılı tutulmalı (600 ms) ya da ⌘⏎
  kullanılmalı.
- **Klavye (panel ⌃⌥Space ile açılınca):** ⌘⏎ İzin ver, ⌘⇧⏎ Her zaman, ⌘⌫ Reddet, ←/→
  istekler, ↑/↓ oturumlar, Boşluk tüm metni aç / sonraki sayfa, ⏎ terminale git, Esc kapat.
  Her karar yeni bir tuş basışı ister: basılı tutulan ⌘⏎ (tuş tekrarı) yalnızca bir kartı
  onaylar, sonraki karar için tuşun bırakılması gerekir. ⌘⇧⏎ önce kuralı gösterir; kural en az
  0,8 sn ekranda kaldıktan sonra ikinci, ayrı bir basış kaydeder. Fare tıklamaları odağı çalmaz.
- **Oturum keşfi:** hook'lar kurulmadan önce başlamış ya da o zamandan beri hiç olay
  göndermemiş oturumlar da listede görünür. Uygulama açılışta ve her ~5 sn'de süreçleri kendi
  içinde tarar (libproc / sysctl; `ps` çalıştırmaz): adı / yolu `claude` olan (bu makinede
  `~/.local/share/claude/versions/<sürüm>`, `claude` olarak başlatılır; npm kurulumunda
  `node …/@anthropic-ai/claude-code/cli.js`), bir terminali (tty) olan ve üst süreci (aradaki
  kabuklar atlanarak) başka bir claude olmayan her süreç. Bir hook oturumunun sahip olmadığı her
  tty için bir satır açılır (arayüzde yalnızca **Boşta** görünür): proje = çalışma dizininin son parçası, durum
  **Boşta** (sahte etkinlik yok), terminal TERM_PROGRAM'dan. Aynı tty / pid'den ilk hook olayı
  gelince satır o hook oturumuna dönüşür (session_id hook'unki olur, çizgideki yeri değişmez,
  çift satır olmaz). Keşfedilen satırlar sürecin gerçek başlama zamanına göre sıralanır. Süreç
  çıkınca satır kalkar. `SessionEnd`'den sonraki 10 sn yeniden
  keşfedilmez (/clear).
- **Sekme adı (Ghostty):** Ghostty için Otomasyon izni **zaten verilmişse** (uygulama izni
  kendiliğinden sormaz) panel açılınca ve oturum varken ~15 sn'de bir, iki ham Apple Event
  `get` isteğiyle (her terminalin `tty` ve `name` değeri; AppleScript derlenmez) sekme adları
  okunur. Ad sohbetin başlığıdır: satırda kalın olarak önde durur, proje adı ardından gri
  yazılır; henüz başlığı olmayan sohbette proje önde kalır. Ad aynı projedeki oturumları da
  ayırt eder (ad da aynıysa projenin yanına dal / tty eki eklenir).
  Kontrol, çift yönlü ve görünmez karakterler atılır, Claude Code'un baştaki dönen / durum
  simgesi (⠂ ◐ ✳) silinir, uzun adın ortası kısaltılır. İzin yoksa eski ayırt edici (dal, tty
  eki) kullanılır.
- Satırın herhangi bir yerine tıklamak o oturumun **sekmesini** öne getirir (Ghostty, Terminal,
  iTerm2 için tty ile; diğer terminallerde yalnızca uygulama) ve panel kapanır, sekme görünür
  olur (sabitlenmiş panel açık kalır). İzin kartında ve çentikte
  yanıtlanan soruda tıklama yalnızca kendi düğmelerine gider. Sekmeye ulaşılamazsa (kapanmışsa
  ya da terminal yanıt vermediyse) panel bunu sohbetin başlığıyla söyler; yalnızca terminal
  uygulamasını öne getirip susmaz. Satır üzerindeki düğmeler: Son mesajı kopyala, Okundu,
  Gizle (sekmeye geçmek için satırın kendisine tıklanır). İlk odaklamada macOS Otomasyon izni ister. Panel her açılışta kendi
  seviyesinin en önüne geçer; aynı seviyedeki başka bir uygulamanın penceresi (ör. Superwhisper)
  onu örtüp tıklamalarını alamaz.
- **Sohbeti gizle:** satırın üzerine gelip üstü çizili göze tıklayın; sohbet panelden ve durum
  çizgisinden çıkar, terminali ve süreci olduğu gibi kalır. Yeni bir şey olunca kendiliğinden
  geri gelir: içine yazdığınızda, bir tur bittiğinde ya da hata verdiğinde, ya da sizi
  beklediğinde (izin isteği, soru, plan onayı). Claude Code’un turdan bir dakika sonra gelen
  "girdi bekleniyor" bildirimi onu geri getirmez. İzin isteği, soru, plan onayı ya da okunmamış hatası olan bir sohbet gizlenemez; yalnızca bir sonraki istemi bekleyen sohbet gizlenebilir.
  Satırların altındaki **Gizli** satırı gizlenen sohbetleri başlıklarıyla listeler: birine
  tıklamak onu geri getirir, **Hepsini göster** hepsini.
- **Ghostty iznini ver:** Otomasyon izni henüz sorulmadıysa ya da reddedildiyse panel bandında
  amber kilit simgesi ve sağ tık menüsünde "Ghostty iznini ver…" görünür. Tıklamak macOS izin
  penceresini açar (arka planda; çentik donmaz). Daha önce reddedildiyse Sistem Ayarları >
  Gizlilik ve Güvenlik > Otomasyon açılır.
- **Bakınca görüldü (Ghostty; Erişilebilirlik isteğe bağlı):** bitmiş ya da bekleyen bir
  sohbetin parçası, onun Ghostty sekmesine ya da bölmesine geçince temizlenir. Varsayılan olarak
  Ghostty öndeyken ve bir Ghostty sohbeti varken çentik Ghostty'ye odaktaki terminali 0,5 sn'de
  bir ve her tıklamadan sonra sorar. Ayarlar > Bildirimler > **Anında güncelleme (Erişilebilirlik)**
  > **Erişilebilirliğe izin ver…** ile uygulama bunun yerine Ghostty'nin odak, pencere ve başlık
  değişikliklerini izler: parça geçtiğiniz anda temizlenir, 0,5 sn'lik kontrol ve tıklama
  izleyicisi durur. İzin başka hiçbir şey için kullanılmaz; uygulama onu kendiliğinden istemez,
  izin yoksa her şey eskisi gibi çalışır.
- **Buradasınız (Ghostty):** Ghostty'de içinde olduğunuz sekmenin ya da bölmenin sohbetinin
  durum çizgisi parçası 1,5 pt aşağı doğru uzar ve bu alt şerit beyazdır, çubukla tek parça
  olarak birleşir; böylece önünüzdeki sohbetin hangi parça olduğu görünür. Çubuk kendi rengini
  korur, bu yüzden işaret o sohbet çalışırken, boştayken, sizi beklerken ya da hata verdiğinde
  aynıdır; hiçbir durum düz beyaz kullanmadığı için bir durum gibi okunmaz. Sekme değiştirince
  anında yer değiştirir, başka bir uygulama öne gelince kalkar. "Bakınca görüldü" ile aynı
  odaktaki terminal kontrolünü kullanır (Ghostty için
  Otomasyon; Erişilebilirlik izniyle anında), bu yüzden bu kontrol yalnızca görülmemiş ya da
  bekleyen bir sohbet varken değil, bir Ghostty sohbeti olduğu sürece çalışır. Terminal ve
  iTerm2 sekmeleri bu işareti almaz.
- **Sekme başına bir parça:** durdurulmuş bir Claude süreci (Ctrl-Z ya da `/restart`ın geride
  bıraktığı eski süreç) veya Claude Code'un arka plan servisinin önceden başlattığı yedek süreç
  sohbet sayılmaz. Bu servisin çalıştırdığı bir sohbetin (Claude Code 2.1.328'de `/restart`
  sonrası) süreci gizli bir terminaldedir; çentik onu, sürecin devraldığı sekme kimliğiyle
  (`GHOSTTY_SURFACE_ID`) Ghostty sekmesine bağlar, böylece renkleri, işareti, tıklaması ve
  "görüldü"sü kendi sekmesinde kalır. 10'dan fazla sohbet varken çizgi önce içinde olduğunuz
  sohbeti, sonra en acil olanları gösterir.
- **Birden çok ekran / çentiksiz ekran:** tam arayüz çentikli ekrandadır; çalıştığınız ekran
  başkaysa onun menü çubuğunun ortasında 180 pt'lik siyah bir yapay çentik görünür ve aynı model
  geçerlidir (altında durum çizgisi, kanatlar onun iki yanından büyür, panel onun bandını alır). Ayarlar > Ekran: Otomatik / Sadece
  çentikli / Tümü.
- Sağ tık: gerekiyorsa **Ghostty iznini ver**, **Ayarlar** (ekran, satır yoğunluğu,
  kısayollar, kısayolla açılan panelin açık kalma süresi, olay başına sesler, oturum açılışında
  başlat, kanca kurulumu), **Claude Code kancaları…**, **ClaudeNotch’tan çık**.

## İzin akışı ve kısayollar

**İstek gelince:** ses (Ayarlar > Bildirim sesleri) ve çentiğin iki yanında kanatlar açılır: sol
kanatta "<proje> çalıştırmak istiyor", sağ kanatta tek satır komut. Kanatlarda düğme yoktur:
**⌃⌥Y** (izin ver) ve **⌃⌥N** (reddet) her uygulamadan çalışır, ya da kanatlara tıklayıp paneli
açar ve kartın düğmelerini (kalan süre halkası, kısayol tuşları) kullanırsınız. İmleç kanatların
üzerine gelince "⌃⌥Y izin ver · ⌃⌥N reddet" ipucu çıkar. 4 sn sonra kanatlar, istek yanıtlanana
kadar kalan küçük bir işarete daralır.

**Ne kadar kalır:** kanatlardaki metin 4 sn kalır, sonra istek **bekler**: işareti çentiğin
yanında, çizgideki parçası amber nefes alır, panelde kartı durur. İstek, siz yanıtlayana (kısayol,
panel ya da terminal) veya hook'un ~590 sn'lik süresi dolana kadar yaşar (süre dolarsa
terminaldeki pencere geçerli kalır; köprü hiçbir zaman kendiliğinden izin vermez). Ayarlar >
Bildirim > "Kısayol paneli açınca açık kalsın" (**8 sn / 15 sn (varsayılan) / 30 sn /
Yanıtlanana kadar**) yalnızca kısayolla açılan panelin ne kadar açık kalacağını belirler; imleç
üzerindeyken kapanmaz.

**Global kısayollar** (Carbon `RegisterEventHotKey`; Erişilebilirlik izni gerekmez): her
uygulamadan çalışır, odağı almaz, ClaudeNotch'u öne getirmez.

| Kısayol | Varsayılan | Ne yapar |
| --- | --- | --- |
| Paneli aç | ⌃⌥Space | Paneli klavye kipinde açar / kapatır (aşağıdaki ⌘ tuşları) |
| İzin ver | ⌃⌥Y | Ekranda gösterilen isteğe izin verir |
| Reddet | ⌃⌥N | Ekranda gösterilen isteği reddeder |
| Sizi bekleyen oturuma git | ⌃⌥J | Sizi en çok bekleyen oturumun terminal sekmesini öne getirir: önce izin isteği, sonra soru, plan onayı ya da girdi bekleyen, sonra görülmemiş hata, sonra görülmemiş "bitti"; bekleyen yoksa bir şey yapmaz |

Kurallar (tıklamalarla aynı tek karar yolunda uygulanır, yalnızca görünümde değil):

- Yalnızca **ekranda gösterilen** isteğe uygulanır: kanattaki istek ya da açık paneldeki kart.
  Hiçbir istek gösterilmiyorsa (kanatlar yalnızca işarete daralmışsa) ilk ⌃⌥Y / ⌃⌥N en eski
  bekleyen isteğin metnini 4 sn geri getirir ve **başka hiçbir şey yapmaz** ("yalnızca işaret"
  açıkken bunun yerine paneli açar); karar, ikinci basışta verilir.
- Gösterilen metin tamamı görünmüyorsa (kanatta tek satıra sığmıyor, kartta "Tümünü göster"
  kapalı ya da sonuna kadar okunmamış) ⌃⌥Y izin vermez, **tüm metni açar**: kanatlardan panel o
  kartla açılır (anahtar pencere olmaz, imleç gelene kadar kapanmaz; imleç hiç gelmezse
  **Kısayol paneli açınca açık kalsın** süresi sonunda kapanır), kartta metin açılır; açık ama okunmamış metinde ⌃⌥Y
  bir sayfa kaydırır. Metnin sonunu gösteren sayfadan sonra 0,8 sn beklenir; izin ancak ondan
  sonraki ayrı bir basışla verilir (sayfalama ve izin aynı tuş ritmine düşmez). **Write / Edit /
  MultiEdit / NotebookEdit** isteklerinde yazılacak içerik ya da eski/yeni metin de bu "tüm
  metne" dahildir: kanatta yalnızca dosya yolu görünse bile ⌃⌥Y önce içeriği açar. ⌃⌥N
  kısaltılmış istekte de reddeder (reddetmek güvenlidir), ama yine yalnızca gösterilende.
- **Riskli komutta** (yukarıdaki liste) ⌃⌥Y **0,6 sn basılı tutulmalıdır**: İzin ver
  düğmesindeki halka dolar, tuş bırakılınca dolmadan iptal olur. Kısa basış yalnızca düğmeyi
  "Basılı tutun" diye vurgular. ⌃⌥N basılı tutma istemez.
- Tuş tekrarı yok sayılır: basılı tutulan kısayol bir kez karar verir, sonraki karar için tuş
  bırakılmalıdır. Bekleme süreleri geçerlidir: yeni ya da geri getirilen istek 0,8 sn, bir kart
  kalkınca ~0,5 sn kısayolları da kabul etmez. Panel açıldığında (⌃⌥Space, üzerine gelme ya da
  tıklama) karttaki istek de yeni gösterilmiş sayılır ve 0,8 sn bekler; kanatlardan açılan panel
  kanattaki isteği gösterir, başka birini değil.
- Kanatlardan verilen bir karardan sonra sıradaki bekleyen istek ~0,5 sn sonra kanatlarda
  görünür (aynı basışın altına hiçbir zaman anında gelmez) ve yine 0,8 sn bekler.
- **"Her zaman"ın global kısayolu yoktur** (yalnızca tıklama ya da panel klavye kipinde ⌘⇧⏎).

**Ayarlar > Kısayollar:** üç kısayol kaydedici (Paneli aç, İzin ver, Reddet). Düğmeye tıklayıp
yeni tuş bileşimine basın (en az ⌃, ⌥ ya da ⌘ gerekir; Esc vazgeçer). **İzin ver** ve
**Reddet** her uygulamadan çalıştığı için yazılan ya da uygulama kısayolu olan bir bileşim
olamaz: ⌃ ile birlikte bir değiştirici daha (⌃⌥, ⌃⇧, ⌃⌘) ya da ⌘⌥ gerekir; tek ⌥ / ⌥⇧
(karakter yazar, ör. ⌥Q = @), tek ⌘ / ⌘⇧ (⌘V, ⌘⇧Z…) ve tek ⌃ (terminalde ⌃C…) reddedilir.
Aynı anda yalnızca bir kaydedici dinler (birine tıklamak diğerini durdurur) ve kayıt
sırasında ClaudeNotch kendi kısayollarını geçici olarak bırakır. Diğer iki kısayoldan biriyle çakışırsa,
macOS'un açık bir kısayoluysa (Spotlight, ekran görüntüsü…) ya da kayıt başarısız olursa Türkçe
hata gösterilir ve önceki kısayol korunur. Not: macOS başka bir uygulamanın aynı bileşimi
kullandığını bildirmez; o durumda kısayolu değiştirin. **Varsayılana dön** üçünü sıfırlar.
Değişiklikler UserDefaults'a yazılır ve hemen yeniden kaydedilir. Varsayılan Y / N tuşları
geçerli klavye düzenine göre bulunur.

Aynı sekmede **Caps Lock kullan (Hyper tuşu)** düğmesi tüm kısayolları ⌃⌥⇧⌘ + aynı tuşa taşır
(Caps Lock + Y izin verir, Caps Lock + J oturuma gider…); **Varsayılana dön** yeniden ⌃⌥'ye
döndürür. Soru seçeneği tuşları (⌃⌥1…4) her durumda aynı kalır. Bu düğmelerden birine
basılmadıkça hiçbir şey değişmez. Hyper için Caps Lock'u ⌃⌥⇧⌘ yapan bir araç gerekir: Raycast
(Settings > Advanced > Hyper Key), Hyperkey ya da Karabiner-Elements.

## Notlar ve sınırlar

- `auto` izin modunda `PermissionRequest` nadiren tetiklenir; bu yüzden onay kartları çoğunlukla
  `default` / `acceptEdits` oturumlarında görünür. "Bitti" ve "girdi bekliyor" bildirimleri her
  modda çalışır. Terminalde yanıtlamak her zaman mümkündür.
- **Sessiz mod** (panel bandındaki 🔔): yalnız izin istekleri ve sorular kanatlarda görünür ve ses
  çıkarır. macOS'un Odak durumu ise ayrıca kendiliğinden izlenir (aşağıda Rahatsız Etme'ye
  bakın).
- `AskUserQuestion` çentikten yanıtlanabilir: `PreToolUse` kancası (eşleşen araç
  `AskUserQuestion`) soruyu bekletir, çentikte seçenekler düğme olarak çıkar; seçip **Gönder**
  dendiğinde yanıt `updatedInput.answers` ile Claude Code'a döner (çoklu seçimde etiketler
  ", " ile birleşir). Düğmeler soru göründükten 0,8 sn sonra etkinleşir. **Terminalde yanıtla**,
  o oturumun Ghostty sekmesine geçmek, uygulamanın kapanması ya da 10 dk zaman aşımı soruyu
  terminale bırakır (boş yanıt). Serbest metin ("Diğer") terminalde kalır. Bu kanca
  `scripts/install-hooks.sh` yeniden çalıştırılınca eklenir.
  Ayarlar > Bildirimler > **Claude’un sorularını çentikte yanıtla** kapatılırsa soru hiç
  bekletilmez: terminal hemen sorar, çentik yalnızca "<proje> soruyor:" kanatlarıyla
  haber verir ve kanatlara tıklamak o oturumun terminal sekmesine götürür. Soru geldiğinde o
  terminal uygulaması (Ghostty, Terminal, iTerm2…; VS Code gibi bir düzenleyici değil) öndeyse
  kanat görünmez: soru zaten gözünüzün önündedir, ⌃⌥J yine o sekmeye götürür. Görünen kanat, o
  terminale geçtiğinizde kapanır; soru yanıtlanmadan terminalden ayrılırsanız küçük işareti
  geri gelir.
- Ayarlar > Bildirimler > **Terminali öndeyken kanatları gizle** (varsayılan: kapalı) açıksa, o
  oturumun terminal uygulaması (aynı liste; düzenleyici değil) öndeyken, hangi sekmesinde
  olursanız olun izin istekleri, plan onayları ve "girdi bekliyor" bildirimleri için kanat
  görünmez: terminalde yanıtlanır. Görünen kanat, o terminale geçtiğinizde kapanır. İstekler
  panelde bekler; yanıtlanmadan bırakılan bir istek, o terminal önden çekilince küçük işaret
  olarak geri gelir (4 sn'lik metin değil).
- Ayarlar > Bildirimler > **Claude Code bildirim gönderince terminal zilini çal** (varsayılan:
  kapalı): Claude Code'un her `Notification` olayında (izin, soru, girdi bekleme; giriş onayı
  hariç) uygulama o oturumun tty'sine bir zil karakteri (BEL) yazar. Ghostty sekmeye bakılana
  kadar başlığa 🔔 koyar; Terminal ve iTerm2 sekmeyi işaretler (zilleri görsel olarak
  ayarlanmadıysa ses de çıkarır). Sessiz modda yalnızca yanıt bekleyen bildirimler çalar. Uygulama kapalıyken
  zil çalmaz. Claude Code'un kendisi de zil çalacak şekilde ayarlıysa (`preferredNotifChannel`:
  `terminal_bell`) her bildirim iki kez çalar.
- Sohbetin turu, başlattığı bir workflow ya da arka plan ajanı hâlâ çalışırken biterse
  (Claude Code bunu `Stop` kancasında listeler) oturum "çalışıyor" kalır ve "Arka planda: …"
  yazar: bitti kanadı ya da sesi, "10 dk’dır sessiz" notu ve "girdinizi bekliyor" gelmez. Bitti,
  o iş dönüp tur gerçekten bitince gelir. Arka planda çalışan bir kabuk komutu ya da izleyici
  (geliştirme sunucusu, log takibi) bunu bekletmez.
- `ExitPlanMode` (plan onayı) terminalde kalır: çentikte "Plan onayı bekliyor" görünür.
- İzni terminalde **reddederseniz** `PostToolUse` gelmez; kart, aynı oturumdaki (ve aynı
  alt ajandaki) farklı bir `PreToolUse` (1,5 sn'den sonra), `UserPromptSubmit`, `Stop`,
  `StopFailure`, `SessionEnd` ya da `idle_prompt` bildirimiyle temizlenir. Aynı çağrı yeniden
  istenirse eski kart yenisiyle değiştirilir. Ana ajanın `Stop` olayı alt ajan kartlarını silmez.
- Kartta komut/yol/URL uzunsa baş ve son kısmı gösterilir, ortası "[N karakter gizli]" olarak
  işaretlenir; **İzin ver** ve **Her zaman** düğmeleri (ve ⌘⏎) "Tümünü göster" açılıp metin
  sonuna kadar kaydırılana kadar kapalıdır ("Sonuna kadar kaydırın"; klavyede Boşluk sayfa
  sayfa ilerler).
  Satır sonu, sekme, kontrol, çift yönlü ve sıfır genişlikli karakterler `\n`, `\u{202E}` gibi
  görünür hale getirilir. MCP argümanları kartta; Write/Edit içeriği tüm metin görünümünde
  (yol kısa olsa da İzin ver içerik sonuna kadar okunana kadar kapalıdır).
- Yeni kartın düğmeleri (Reddet dahil) ~0,8 sn, bir kart kalkınca diğerleri sistemin çift
  tıklama süresi + 0,1 sn (en az 0,45 sn; varsayılan 0,5 sn ile 0,6 sn), sayfalayıcıyla kart
  değişince ~0,8 sn devre dışıdır: bir çift tıklamanın ikinci tıklaması yerine kayan karta
  inmez. "Her zaman" ⋯ açıldıktan ~0,8 sn sonra etkinleşir.
- Oturumun claude süreci çıkınca (kill -9, sekme kapandı; süreç henüz toplanmamış bir zombi
  olsa bile) satır ve kartları hemen kalkar; 10 sn'lik yoklama yedek olarak çalışır.
  Kanatlar durağan imlecin altında açılırsa imleç hareket edene
  kadar tıklamaları arkadaki pencereye geçirir.
- Çentiksiz ekranda ve gösterecek bir şey yokken panel görünmezdir ve fareyi yakalamaz.
- "Oturum açılışında başlat" ad-hoc imzalı uygulamalarda hata verebilir; uygulamayı
  `/Applications` altına taşıyın.
- **Raf** (Ayarlar > Modüller): panelde tek satıra katlanmış durur (RAF ve öğe sayısı); satıra
  tıklayınca kopyalanan öğeler açılır, panel her açılışta yeniden katlanır. Sabitlenmemiş
  öğeler geçici klasörde durur, raf kapatılınca ya
  da uygulama yeniden başlayınca silinir; sabitlenenler diskte kalır. İsteğe bağlı iki ayar:
  **Sabitlenmemiş öğeleri sil** 1 / 3 / 7 gün sonra (varsayılan: Hiçbir zaman) ve **Raf
  kapatılınca sabitlenenleri de sil** (varsayılan: kapalı).
- **Claude planı** (`scripts/install-statusline.sh`): halka 5 saatlik ve haftalık pencereden
  dolu olanı gösterir, %80 ve %95 uyarıları 5 saatlik pencere içindir. Durum satırı yalnız
  haftalık pencereyi (`rate_limits.seven_day`) gönderiyorsa (yeni Claude Code sürümleri) halka
  haftalık limiti izler; uyarılar ise yalnızca Ayarlar > Modüller > **Haftalık limit %80’e,
  sonra %95’e gelince uyar** açıksa (varsayılan: kapalı) haftalık limit için gelir.

## Rahatsız Etme ve diğer Odak modları

ClaudeNotch macOS'un Odak durumunu kendisi izler: `~/Library/DoNotDisturb/DB/Assertions.json`
dosyasını okur (açık olan her Odak, Rahatsız Etme ya da başkası, elle ya da zamanlamayla açılmış
olsun, orada bir kayıttır) ve değişince yeniden okur. Kanatların kuralı iki cümledir:

- **Odak kapalı:** her şey (izin istekleri, sorular, plan onayları, girdi beklemeleri, biten
  işler, hatalar, modül notları) metnini 4 sn gösterir, **Çentiğin yanında yalnızca küçük bir
  işaret göster** açıksa hemen işaretini; sonra yalnızca Claude’u bekleten şeyler (izin, soru,
  plan, bekleme) siz ilgilenene kadar işaret bırakır.
- **Odak açık:** yalnızca Claude’u bekleten şeyler görünür (iki soru modunda da), o da yalnızca
  küçük işaret olarak, 4 sn'lik metin olmadan; siz ilgilenene kadar kalır. Biten işler, hatalar
  ve modül notları çentiğin yanında hiç görünmez; durum çizgisi onları yine gösterir.

Sesler de aynı kuralı izler: Odak açıkken yalnızca Claude’u bekleten şeylerin (izin istekleri,
sorular, plan onayları, girdi beklemeleri) sesi çalar; biten işler, hatalar ve modül sesleri
(zamanlayıcı, takvim hatırlatıcısı) sessizdir.

Ayarlar > Bildirimler > **Odağı açık say** (varsayılan: kapalı) bir yedektir: macOS ya da bu
düğme açık diyorsa Odak açık sayılır. Uygulama bu dosyayı okuyamıyorsa (dosya yok ya da gizlilik
ayarları engelliyor; Bildirimler sekmesinde o zaman "macOS Odak durumu okunamıyor" yazar), düğmeyi
iki Kestirmeler otomasyonu sizin yerinize açıp kapatabilir:

1. Kestirmeler > Ayarlar > İleri Düzey: **Betikleri Çalıştırmaya İzin Ver**'i açın.
2. Otomasyon > Yeni Otomasyon > **Odak** > Rahatsız Etme > **Açılırken**, Hemen Çalıştır. Şu
   komutla bir **Kabuk Betiği Çalıştır** eylemi ekleyin:
   ```sh
   /usr/bin/defaults write com.eyyupcan.claudenotch focusActive -bool true; /usr/bin/notifyutil -p com.eyyupcan.claudenotch.focus
   ```
3. **Kapanırken** için ikinci bir otomasyon; aynı komutta `-bool false`.

Uygulama yeni değeri hemen okur. Diğer Odak modları da aynı şekilde bağlanır.
`CLAUDE_NOTCH_DEBUG=1` ile `/debug/state`, uygulamanın gördüğünü `ui.focus` altında gösterir
(`file`: on / off / unknown, `file_readable`, `file_error` (neden okunamadığı), `shortcuts`, `on`).

## Hata ayıklama

Çentikteki bir tıklama hiçbir şey yapmıyor gibi görünürse birleşik günlük nerede durduğunu
söyler: basış panele mi ulaştı yoksa başka bir uygulamaya mı gitti, ve terminale her atlama
nasıl bitti (`terminal`, `directory`, Apple Event hata koduyla `tab_missed`, ...). Günlükte
sohbet adı ya da yol yoktur.

```sh
log show --last 1h --style compact --predicate 'subsystem == "com.eyyupcan.claudenotch"'
```

`/debug/*` uçları kartları onaylayabildiği için **varsayılan olarak kapalıdır** (404). Yalnızca
`CLAUDE_NOTCH_DEBUG=1` ile başlatılan uygulamada açılır (soket yine yalnızca sizin kullanıcınıza
açıktır):

```sh
open -n --env CLAUDE_NOTCH_DEBUG=1 build.noindex/ClaudeNotch.app
SOCK=~/Library/Application\ Support/ClaudeNotch/notch.sock
curl -s --unix-socket "$SOCK" http://localhost/debug/state | jq
curl -s --unix-socket "$SOCK" -d '{"id":"<kart id>","decision":"allow"}' http://localhost/debug/decide
# decision: allow | always | deny (isteğe bağlı "message")
scripts/shot.sh out.png                        # panelin PNG görüntüsü
```

Debug modda `POST /debug/ui` (`{"mode":"expanded","freeze":true}`, `active_display`,
`select_card`, `more_card`, `density`, `display_mode`, `pin`) ve `POST /debug/key`
(`{"hotkey":true}`, `{"key":"right"}`; paneli anahtar pencere yapmadan klavye kipi için
`{"key_mode":true}`; `"phase":"down"|"up"` ve `"repeat":true` tuş basılı tutmayı taklit eder)
görsel testler içindir. `POST /debug/key {"global": "allow"|"deny"|"panel", "phase":
"down"|"up"|"press"}` global kısayolu Carbon olayıyla aynı yoldan taklit eder (`down` ile
`up` arası basılı tutmaktır). `POST /debug/ui` ayrıca `{"shortcut_hint": true}` (ilk kullanım
satırını geri getirir), `{"peek_duration": "8"|"15"|"30"|"answered"}`, `{"set_shortcut":
{"role": "allow", "keys": [tuş kodu, Carbon değiştiricileri]}}`, `{"reset_shortcuts": true}`,
`{"open_settings": true}` / `{"close_settings": true}`, `{"hide": "<oturum id>"}` /
`{"unhide_all": true}` (satırdaki gizle düğmesi / "Hepsini göster"), `{"shelf_open": true}`
(katlı rafı açar) ve `{"shelf_add_file": "/tam/yol"}` (panoya dokunmadan rafa dosya ekler) alır. `POST /debug/discover` hemen bir
süreç taraması yapar ve oturumları döndürür. `POST /debug/focus` (`{"session_id": "…", "dry_run": true}`) odaklama betiğini ve
Otomasyon durumunu döndürür; `dry_run` olmadan gerçekten odaklar.

Uçtan uca testler: `python3 -I Tests/e2e/drive.py <allow|deny|terminal|stop|esc|no|noapp|identity>
<settings.json> <çalışma dizini> <test dizini>` (`noapp` için uygulama kapalı olmalı; diğerleri için
debug modda açık olmalı). Test için `scripts/install-hooks.sh --settings <dosya>` ile ayrı bir
ayar dosyası üretin.
