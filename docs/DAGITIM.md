# Dağıtım: imza, DMG, otomatik güncelleme

Apple Developer hesabı ve notarization yok. Uygulama yerel, kendinden imzalı bir sertifikayla imzalanır,
DMG olarak verilir ve Sparkle 2 ile güncellenir. Appcast ve DMG'ler herkese açık depo
`github.com/aichera-ant/cleaner`'ın GitHub Releases sayfasında durur.

## 1. Tek seferlik kurulum (geliştirici Mac'i)

### İmza sertifikası

```
scripts/make-signing-cert.sh
```

- "Hepp Cleaner Local" adlı kendinden imzalı Kod İmzalama sertifikası üretir (RSA 2048, ~20 yıl,
  extendedKeyUsage codeSigning), login anahtar zincirine koyar ve yalnız kod imzalama için güvenilir yapar.
- Özel anahtar yalnız geçici dizinde durur, betik bitince silinir. Kimlik varsa betik bir şey yapmaz.
- macOS güven ayarı için parola/Touch ID isteyebilir. `codesign` anahtar erişimi sorarsa "Her Zaman İzin Ver".
- Özel anahtarın erişim listesinde (ACL) yalnız `/usr/bin/codesign` var; partition list önerisi yalnız
  `codesign:`. `/usr/bin/security` ve `apple-tool:` bilinçli olarak yok: aksi hâlde aynı kullanıcıyla çalışan
  herhangi bir betik `security` üzerinden anahtarı sormadan kullanabilir ya da dışa aktarabilir.
- **Eski kurulumdaki anahtarı daraltma (elle, bir kez).** Betiğin eski sürümü anahtarı
  `-T /usr/bin/security` ve `apple-tool:,apple:,codesign:` ile eklemişti; betik mevcut öğeye dokunmaz.
  1. Anahtar Zinciri Erişimi > login > Anahtarlar > "Hepp Cleaner Local" özel anahtarı > Bilgi Al >
     Erişim Denetimi: listede `security` varsa seçip "−" ile silin, yalnız `codesign` kalsın,
     Değişiklikleri Kaydet (parola ister).
  2. Terminal (login parolasını sorar):
     `security set-key-partition-list -S codesign: -s -l "Hepp Cleaner Local" ~/Library/Keychains/login.keychain-db`
  3. `scripts/build-app.sh` ile deneyin. codesign artık anahtar erişimi sorarsa "Her Zaman İzin Ver";
     yine her seferinde sorarsa 2. adımı `-S apple-tool:,codesign:` ile yineleyin (yalnız `codesign:`
     ile sorunsuz çalıştığı bu Mac'te henüz doğrulanmadı).
- Doğrulama: `security find-identity -v -p codesigning` çıktısında `"Hepp Cleaner Local"`.

Neden: ad-hoc imzada her derlemenin kimliği (cdhash) değişir; macOS Tam Disk Erişimi ve Otomasyon
(Finder) iznini bu kimliğe bağladığı için her derlemede izinler düşer. Sabit sertifikayla designated
requirement her derlemede aynıdır:

```
identifier "com.aichera.cleaner" and certificate root = H"<sertifika SHA-1>"
```

Kontrol: `codesign -d -r- "build/Hepp Cleaner.app"` iki derlemede aynı satırı vermeli.

### Sparkle EdDSA anahtarı

Bir kez üretildi (2026-10-18); genel anahtar `App/project.yml` içinde `SUPublicEDKey`. Özel anahtar
login anahtar zincirinde ("Private key for signing Sparkle updates", hesap `ed25519`) ve depoya asla girmez.
Yeniden gerekmesi hâlinde (derleme bir kez çalıştıktan sonra araçlar `build/DerivedData` altında):

```
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys      # varsa mevcut anahtarı gösterir
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -p   # yalnız genel anahtar
```

## 2. Derleme

```
scripts/build-app.sh                  # build/Hepp Cleaner.app, "Hepp Cleaner Local" ile imzalı
SIGN_IDENTITY=- scripts/build-app.sh  # ad-hoc (izinler her derlemede düşebilir)
CONFIG=Debug scripts/build-app.sh     # --snapshot etkin derleme
```

- İç içe kod içten dışa imzalanır (`--deep` kullanılmaz): Sparkle `Installer.xpc`, `Downloader.xpc`,
  `Autoupdate`, `Updater.app`, `Sparkle.framework`, sonra uygulama. Sonunda
  `codesign --verify --deep --strict` çalışır.
- **Hardened runtime açık** (`--options runtime`, uygulama ve Sparkle'ın bütün parçaları; `project.yml`
  `ENABLE_HARDENED_RUNTIME: YES`). Gerekçe: uygulama Tam Disk Erişimi ve Finder otomasyonu izni taşıyor.
  Runtime kapalıyken aynı kullanıcıyla çalışan herhangi bir süreç uygulamayı `DYLD_INSERT_LIBRARIES` ile
  başlatıp kendi kodunu içine yükleyebilir ve bu izinleri devralır. Runtime açıkken DYLD_* değişkenleri
  yok sayılır (`allow-dyld-environment-variables` verilmedi). Notarization olmasa da bu yüzden açık.
- Entitlement'lar `App/Cleaner.entitlements`:
  - `com.apple.security.automation.apple-events`: Finder'a Apple Event ile Çöp Kutusu'na taşıma. Kullanıcıya
    gösterilen gerekçe `NSAppleEventsUsageDescription` (Info.plist).
  - `com.apple.security.cs.disable-library-validation`: gerekli. Kendinden imzalı sertifikada Team ID yok;
    library validation açıkken aynı sertifikayla imzalı `Sparkle.framework` bile "mapping process and
    mapped file (non-platform) have different Team IDs" hatasıyla yüklenmiyor (2026-10-18, aynı
    sertifika ve runtime ile imzalı küçük bir `dlopen` deneme aracıyla denendi; entitlement eklenince
    yüklendi ve `DYLD_INSERT_LIBRARIES` yine yok sayıldı). Kalan risk: uygulama kendisi diskten bir
    kitaplık yüklerse imza denetlenmez; uygulama `dlopen` kullanmıyor. Ayrıca kitaplık doğrulaması kapalı olduğu
    için uygulama paketine yazabilen bir süreç `Sparkle.framework` ikilisini değiştirip izinleri devralabilir;
    `/Applications` altında Uygulama Yönetimi koruması bunu büyük olasılıkla engeller (doğrulanmadı),
    `~/Applications` gibi korumasız yerde risk büyür. Kalıcı çözüm Developer ID sertifikası (Team ID).
- Sparkle parçaları Sparkle'ın önerdiği gibi runtime ile imzalanır; `Downloader.xpc` entitlement'ı
  `--preserve-metadata=entitlements` ile korunur. Betik sonunda runtime bayrağı yoksa hata verir.
- Sürüm `App/project.yml`'da: `MARKETING_VERSION` (görünen, ör. 0.3.0) ve `CURRENT_PROJECT_VERSION`
  (artan tam sayı). Sparkle sürümleri **CFBundleVersion** ile karşılaştırır: her yayında 1 artırın,
  aynı ya da küçük numaralı yayın güncelleme olarak görünmez.
- Sparkle `App/project.yml`'da exact sürüme sabit (2.10.0). xcodebuild kökteki `Package.resolved`'a
  Sparkle'ı yazdığı için betik o dosyayı derleme sonunda eski hâline getirir.

## 3. Sürüm çıkarma

1. `App/project.yml`: `MARKETING_VERSION` gerekiyorsa, `CURRENT_PROJECT_VERSION` mutlaka +1.
2. Commit.
3. `scripts/release.sh` (isteğe bağlı `RELEASE_NOTES=notlar.html`, HTML parçası appcast'e gömülür).
   - Derler, `build/release/Hepp-Cleaner-<sürüm>.dmg` üretir (Uygulamalar kısayollu, aynı kimlikle imzalı).
     `make-dmg.sh` ad-hoc imzalı ya da runtime'sız uygulamadan DMG üretmez.
   - `sign_update` ile EdDSA imzası alır, `build/release/appcast.xml` yazar. İndirme adresi
     `https://github.com/aichera-ant/cleaner/releases/download/v<sürüm>/Hepp-Cleaner-<sürüm>.dmg`.
   - İmzayı Info.plist'teki `SUPublicEDKey` ile doğrular (OpenSSL 3+, `brew install openssl`).
   - Anahtar zinciri erişimi sorulursa "Her Zaman İzin Ver" (sign_update için ayrı sorulur).
   - **Yayınlamaz.** Sonda çalıştırılacak `gh release create` komutunu yazdırır; ama yalnız şu denetimler
     tutarsa (`scripts/release-check.sh`, anahtar zincirine dokunmaz, tek başına da çalışır):
     derlenmiş `SUFeedURL` üretim adresi; `DOWNLOAD_BASE` `https://github.com/aichera-ant/cleaner/` ile
     başlıyor; `FEED_URL`, `BUILD_NUMBER`, `SIGN_IDENTITY` ezilmemiş; Info.plist sürümü `project.yml`'dakiyle
     aynı (`SKIP_BUILD=1` ile eski deneme derlemesi kullanılmasın); designated requirement
     `certificate root` içeriyor (ad-hoc değil); hardened runtime bayrağı açık; EdDSA imzası yerelde
     doğrulandı. Biri tutmazsa sorunları listeler, "DENEME DERLEMESİ, YAYINLAMAYIN" yazar ve 1 ile çıkar
     (DMG ve appcast yerel deneme için yine üretilir).
4. Yazdırılan `gh release create v<sürüm> ... --latest` komutunu çalıştırın. Uygulamadaki
   `SUFeedURL` = `https://github.com/aichera-ant/cleaner/releases/latest/download/appcast.xml`, yani
   "latest" işaretli yayının appcast'i okunur; ön sürüm (prerelease) olarak yayınlamayın.

Not: Sparkle'ın `generate_appcast` aracı kullanılmıyor. DMG'yi okumak için bağlıyor ve macOS 27 bu
bağlamada ekranda kendi "Bu uygulama yüklensin mi?" kurulum penceresini açtı (2026-10-18). `release.sh`
DMG'yi hiç bağlamaz.

Her yayının appcast'i yalnız o sürümü içerir (delta güncelleme yok). Eski sürümdeki kullanıcı doğrudan
son sürüme güncellenir.

## 4. Arkadaşlar için kurulum

1. GitHub Releases'ten `Hepp-Cleaner-<sürüm>.dmg` indirin, açın.
2. **Hepp Cleaner**'ı **Uygulamalar** kısayoluna sürükleyin.
   - macOS DMG'yi açınca kendi kurulum penceresini gösterebilir ("Bu uygulama yüklensin mi?").
     "Yüklenemedi. Hiçbir şey değiştirilmedi." derse pencereyi kapatıp uygulamayı Uygulamalar'a
     sürükleyin; sonuç aynıdır. (Bu pencerenin notarize edilmemiş uygulamada çalışıp çalışmadığı
     denenecek.)
3. İlk açılışta macOS "Apple, Hepp Cleaner'ın kötü amaçlı yazılım içermediğini doğrulayamadı" der:
   **Bitti**'ye basın, **Sistem Ayarları > Gizlilik ve Güvenlik**'e gidin, aşağıda Hepp Cleaner için
   **Yine de Aç**'a basın, parola/Touch ID ile onaylayın. Bu bir kez yapılır.
4. Uygulama içindeki izinler ekranından Tam Disk Erişimi ve Finder otomasyonu izni verin.

## 5. Güncellemede ne olur

- Uygulama günde bir kez appcast'i denetler (`SUScheduledCheckInterval` 86400). Yeni sürüm varsa sorar;
  kendiliğinden indirip kurmaz (`SUAutomaticallyUpdate` NO, karar). Elle: uygulama menüsü ve
  menü çubuğu menüsünde "Güncellemeleri denetle…".
- Sparkle 2.10.0 iki yöntemi denetler (`SUUpdateValidator.m`, `validateUpdateForHost`): DMG'nin EdDSA
  imzası eski uygulamanın `SUPublicEDKey`'i ile tutuyor mu, yeni uygulama eski uygulamanın kod imzasıyla
  eşleşiyor mu. **Biri geçerse güncelleme kabul edilir** (anahtar değiştirmeye izin vermek için). EdDSA
  geçip yeni uygulama başka bir sertifikayla imzalıysa, imzası bozuk olmadığı sürece kabul edilir. Yani
  EdDSA anahtarı aynı kaldıkça sertifika değişse de güncelleme gelir; ikisi birden değişirse reddedilir.
  (Kaynak koddan okundu; sertifika değişimiyle gerçek güncelleme denenmedi.)
- Sertifika değişiminin asıl etkisi izinlerdir: designated requirement değişir, macOS Tam Disk Erişimi ve
  Otomasyon iznini yeni uygulamaya vermez; kullanıcı izinleri yeniden verir.
- **İzinler:** designated requirement aynı kaldığı için Tam Disk Erişimi ve Otomasyon izninin korunması
  beklenir. Denenecek (ilk gerçek güncellemede kontrol edin).
- **Gatekeeper:** Sparkle'ın indirdiği dosyaya karantina özniteliği uygulanıp uygulanmadığı ve güncellenen
  uygulamada "Yine de Aç"ın yeniden istenip istenmediği denenecek. İstenirse bölüm 4'teki adım 3 yinelenir.

### Yerel güncelleme denemesi (yayın yapmadan; henüz denenmedi, Sparkle http feedi reddederse https gerekir)

```
# eski sürüm (yapı N), yerel feed ile
BUILD_NUMBER=N FEED_URL=http://127.0.0.1:8765/appcast.xml scripts/build-app.sh
ditto "build/Hepp Cleaner.app" /tmp/eski/"Hepp Cleaner.app"
# yeni sürüm (yapı N+1) ve appcast
BUILD_NUMBER=$((N+1)) FEED_URL=http://127.0.0.1:8765/appcast.xml DOWNLOAD_BASE=http://127.0.0.1:8765/ scripts/release.sh
# (release.sh ezmeleri görüp "DENEME DERLEMESİ, YAYINLAMAYIN" ile 1 döner; dosyalar yine üretilir)
( cd build/release && python3 -m http.server 8765 --bind 127.0.0.1 )
# /tmp/eski'deki uygulamayı açın → "Güncellemeleri denetle…" → kurun; yeniden açılan sürüm N+1 olmalı.
```

Not: deneme kopyası açıldığında oturum açılışı öğesini kaydeder ve izleme başlar; denemeden sonra
Ayarlar'dan kapatın ya da kopyayı silin.

## 6. Yeni Mac'e geçiş: YEDEKLEYİN

İki gizli parça yalnız bu Mac'in login anahtar zincirinde durur. Kaybolurlarsa:

- **"Hepp Cleaner Local" sertifikası + özel anahtarı:** yeni sertifikayla imzalanan sürüm eski sürümün
  designated requirement'ını karşılamaz; EdDSA anahtarı aynıysa Sparkle güncellemeyi yine kurar (bölüm 5),
  ama kullanıcılar Tam Disk Erişimi ve Otomasyon iznini yeniden vermek zorunda kalır. Yedek: Anahtar Zinciri Erişimi > login > Sertifikalarım > "Hepp Cleaner Local"
  > Dışa Aktar (.p12, güçlü parolayla). Yeni Mac'te çift tıklayıp içe aktarın, ardından
  `scripts/make-signing-cert.sh` güven ayarını tamamlar.
- **Sparkle EdDSA özel anahtarı:** kaybolursa mevcut kurulumlara bir daha güncelleme gönderilemez
  (yeni anahtar eski uygulamadaki `SUPublicEDKey` ile tutmaz). Yedek:
  `generate_keys -x sparkle-ed25519.key`, yeni Mac'te `generate_keys -f sparkle-ed25519.key`.

Yedek dosyaları depoya, buluta şifresiz ya da sohbete koymayın; parola yöneticisi ya da şifreli disk.
`.gitignore` `*.p12`, `*.key`, `*.pem` dosyalarını dışarıda tutar; yine de proje klasörüne koymayın.
