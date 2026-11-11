# Zabbix MySQL → PostgreSQL (TimescaleDB) Geçişi — Teknik Plan ve Runbook

Bu belge geçişi yapacak ekip içindir. Müşteriye verilecek belge `02-musteri-gecis-plani.md`,
duyuru metinleri ve müşteri kontrol listesi `03-musteri-duyuru-sablonu.md` dosyasındadır.

## 1. Özet

| | |
|---|---|
| Kaynak | MySQL 8.4.11, `zabbix` veritabanı 236 GB, 207 tablo (AlmaLinux 10.2, 4 vCPU / 23 GB) |
| Zabbix | 7.4.13, `d724zbx01` (Oracle Linux 9.8, 16 vCPU / 38 GB), 2203 NVPS, 2149 host, 226 bin item, 16 proxy |
| Hedef | PostgreSQL 17 + TimescaleDB 2.28.3 (Community), MySQL klonu VM'in üzerinde |
| Taşınan veri | Tamamı: konfigürasyon, olaylar, history, trends, auditlog |
| Kesinti | Hedef 25–40 dk, taahhüt en fazla 60 dk |
| Geri dönüş | Canlı MySQL'e hiç yazılmaz; `13-rollback.sh` ile birkaç dakikada eski hale dönülür |

236 GB veri bir kesinti penceresine sığmadığı için aktarım üç faza bölündü:

1. **Faz 1 — Toplu aktarım (kesintisiz):** Klon VM'deki MySQL'den aynı VM'deki PostgreSQL'e
   history/trends/auditlog aktarılır. Canlı sisteme hiç yük binmez. Eski veriler aktarılırken sıkıştırılır.
2. **Faz 2 — Yakalama (kesintisiz):** Klonun alındığı andan bu yana biriken veri **canlı MySQL'den
   sadece okunarak** PostgreSQL'e eklenir. İstenildiği kadar tekrarlanır; her tekrar aradaki farkı küçültür.
3. **Faz 3 — Geçiş (kesinti):** Zabbix durdurulur, son fark (birkaç dakikalık veri) ve tüm konfigürasyon
   tabloları (~5 GB) aktarılır, doğrulanır, Zabbix PostgreSQL'e bağlanıp açılır.

Bu yöntemde klon ile geçiş anı arasındaki veri **kaybolmaz**; baştaki "aradaki veriyi feda ederiz"
varsayımına gerek kalmadı. Gerçekten oluşabilecek kayıplar Bölüm 4'te.

## 2. Süre tahminleri

Tahminler küçük ölçekli test ortamındaki ölçümlere ve veri boyutuna dayanır. **Kesin süreler prova
sırasında gerçek veriyle ölçülecek** (Bölüm 9'daki tablo) ve müşteriye bildirilen pencere buna göre
teyit edilecek.

| Adım | Tahmini süre | Kesinti |
|---|---|---|
| Hazırlık: dosyalar, `config.env`, ön kontrol, klon ayarları | 30–45 dk | Yok |
| PostgreSQL + TimescaleDB kurulumu, boş şema | 10–15 dk | Yok |
| Faz 1 toplu aktarım (236 GB) + sıkıştırma | 6–16 saat, arka planda (gece) | Yok |
| Toplu aktarım doğrulaması (örneklem) | 10–30 dk | Yok |
| İlk yakalama | klonun yaşı × 20–40 dk/gün | Yok (canlıda 2 okuma bağlantısı) |
| Sonraki yakalamalar | 5–20 dk | Yok |
| Geçiş provası (`--rehearsal`) | 8–15 dk | Yok |
| Zabbix server hazırlığı (`10-prepare.sh`) | 5 dk | Yok |
| **Geçiş** | **25–40 dk (pencere 60 dk)** | **Var** |
| Temizlik (`08-finalize.sh`), 1 hafta sonra | 10 dk | Yok |

Takvim olarak: 1. gün hazırlık + toplu aktarımın başlatılması, 2. gün doğrulama + prova, ardından müşteri
duyuru süresi (öneri: en az 3 iş günü), geçiş gecesi, 1 hafta izleme. Toplam efor yaklaşık 1,5 adam-gün.

### Kesinti penceresi (dakika dakika)

| Zaman | İş | Süre |
|---|---|---|
| T−60 | Son büyük yakalama: `./05-catchup.sh` | 10–20 dk |
| T−30 | Kontroller: `./status.sh`, proxy'ler bağlı, bakım periyodu tanımlı, ekip hazır | |
| T−10 | Kısa bir yakalama daha: `./05-catchup.sh` (bitince beklemeden T0) | 3–5 dk |
| **T0** | Zabbix server: `./11-stop.sh` — **kesinti başlar** | 1–5 dk |
| T+5 | vCenter: `d724zbx01` snapshot (bellek dahil **değil**) | 1–2 dk |
| T+7 | DB: `./06-cutover.sh` (son fark + konfigürasyon + doğrulama) | 6–12 dk |
| T+20 | Zabbix server: `./12-switch.sh` | 2–4 dk |
| T+25 | Kontrol listesi (Bölüm 7.4) | 10–15 dk |
| **T+40** | **Karar noktası:** devam ya da geri dönüş | |
| T+45 | "Hizmet açıldı" duyurusu — ya da `./13-rollback.sh` (2–5 dk) | |

Kural: T+45'te çözülmemiş ciddi bir sorun varsa tartışılmaz, geri dönülür. Böylece en kötü durumda da
kesinti 60 dakikanın altında kalır.

## 3. Geçişten önce netleşmesi gerekenler

| # | Konu | Not |
|---|---|---|
| 1 | Klon VM'in IP adresi (yeni DB adresi) | Canlı MySQL `10.0.29.4`; klon farklı IP ile açılmış olmalı |
| 2 | `d724zbx01` IP adresi | `pg_hba.conf` için (`ZABBIX_SERVER_IP`) |
| 3 | Datastore tipi (SSD/flash mı, dönen disk mi) | VMware sanal diskleri her zaman `ROTA=1` gösterir, oradan anlaşılmaz. `PG_STORAGE_SSD` buna göre |
| 4 | **Global history/trend saklama süresi** | Müşteri kararı — Bölüm 4, madde 1 |
| 5 | Yeni DB VM kaynakları | Öneri: 8 vCPU / 32 GB (şu an 4 / 23). Aktarım hızını doğrudan etkiler |
| 6 | Proxy'lerde `ProxyOfflineBuffer` | Varsayılan 1 saat; pencere 1 saate yaklaşabileceği için en az 3 önerilir (proxy restart ister, günler önce yapılır) |
| 7 | MySQL'e doğrudan bağlanan başka sistem | Envanterde `zabbix` ve `root` dışında MySQL kullanıcısı yok; yine de Grafana, rapor scripti, yedek işi sorulmalı |
| 8 | Geçiş tarihi/saati ve duyuru süresi | Düşük yoğunluklu saat; müşteri onayı |
| 9 | Test klonunun yaşı | 45 günden eskiyse yeniden klonlanmalı (script reddeder); 2 haftadan eskiyse ilk yakalama uzar |

## 4. Ön uyarılar ve riskler

1. **Saklama süresi artık global olacak.** TimescaleDB'de sıkıştırılmış veriyi housekeeper satır satır
   silemez; bu yüzden "Override item history period" ve "Override item trend period" açılır (Zabbix'in
   kendi TimescaleDB kurulumu da bunu yapar). Item/şablon bazındaki "history: 7d / 31d" ayarları yok
   sayılır, herkese global değer uygulanır. Şu an global değerler 90 gün / 365 gün ama kapalı; veri
   boyutuna bakılırsa item'ların fiilî ortalaması 2–3 hafta civarında. Karar `config.env` içindeki
   `HK_HISTORY` / `HK_TRENDS` ile uygulanır. Kaba disk tahmini (sıkıştırma dahil, trends 365 gün):
   history 31 gün → 200–230 GB, history 90 gün → 290–320 GB. Disk 772 GB, ikisi de sığar.
2. **Kesinti sırasında toplanamayan veri.** Proxy arkasındaki hostların verisi proxy'de tamponlanır ve
   Zabbix açılınca gelir. Doğrudan server'ın sorguladığı (proxy'siz) hostlarda kesinti süresi kadar
   grafik boşluğu oluşur; bu sürede gelen SNMP trap'leri kaybolur. Kesinti boyunca alarm üretilmez,
   bildirim gitmez.
3. **Geç gelen eski veri.** Her fark aktarımı bir öncekinin 3 saat gerisinden okur (`OVERLAP`). Geçiş
   dönemi içinde 3 saatten uzun süre kopuk kalıp sonra bağlanan bir proxy'nin tamponundaki eski veri
   pencere dışında kalabilir. Scriptler kopuk proxy'leri uyarı olarak listeler; böyle bir durumda
   `OVERLAP` büyütülüp (en fazla 432000 sn) yakalama yeniden çalıştırılır.
4. **Geri dönülürse** PostgreSQL ile çalışılan süredeki veri MySQL'e taşınmaz; o aralık grafiklerde boş
   kalır. Bu yüzden geri dönüş kararı ilk saatlerde verilmelidir.
5. **Proje boyunca Zabbix güncellenmemeli.** Şema sürümü (7.4.13) iki tarafta birebir aynı olmalı;
   scriptler kontrol eder ve farklıysa durur.
6. **TimescaleDB sürümü sabitlenir** (`versionlock`). Zabbix 7.4.13 en fazla TimescaleDB 2.28.x
   destekler; `dnf update` ile yükselirse Zabbix server açılmaz. PostgreSQL 17 küçük sürüm güncellemeleri
   serbest.
7. **Test PostgreSQL'ine ikinci bir Zabbix server bağlanmamalı.** Aynı konfigürasyonla ikinci server
   çift bildirim gönderir ve proxy'lerle çakışır.
8. **Klon VM canlı ile aynı hostname'i taşıyor** (`d724-zabbix-mysqldb`). Karışmaması için
   `hostnamectl set-hostname` önerilir. Scriptlerin canlıya dokunmasını engelleyen kilitler 6.2'de.
9. **Metin değerlerindeki NUL (0x00) karakteri** PostgreSQL'de saklanamaz, aktarımda atılır. Pratikte
   yalnızca bozuk log/text değerlerinde görülür.
10. **Çevre bileşenler:** veritabanı izleme şablonu (MySQL → PostgreSQL by Zabbix agent 2), yedekleme
    işi (mysqldump → VM yedeği / pg_dump / pgBackRest), DB'ye doğrudan bağlanan araçlar yeni adrese ve
    PostgreSQL'e göre güncellenmeli.
11. **Bildirim fırtınası.** Açılışta biriken veri ve `nodata` tetikleyicileri toplu alarm üretebilir.
    Geçiş penceresi + 1 saat için tüm host gruplarını kapsayan "With data collection" bakım periyodu
    tanımlanmalı. Konfigürasyon geçiş anında kopyalandığı için bakım periyodu **Zabbix durdurulmadan
    önce** girilmiş olmalı.

## 5. Dosyalar

```
collect-info.sh                 envanter (kullanıldı)
zbx-mig/                        → yeni DB makinesine (klon) kopyalanır, root ile çalışır
  config.env.example            ayarlar (config.env olarak kopyalanır)
  00-preflight.sh               ön kontrol, salt-okunur
  01-install-postgres.sh        PostgreSQL 17 + TimescaleDB, ayarlar, roller   (tune: ayarları yeniden yaz)
  02-create-schema.sh           boş Zabbix şeması + hypertable'lar + takip tabloları   (RESET=1: baştan)
  03-bulk.sh                    Faz 1: klon MySQL → PG (kaldığı yerden devam eder)
  04-compress.sh                eski chunk'ların sıkıştırılması (03 kendisi çağırır)
  05-catchup.sh                 Faz 2: canlı MySQL → PG fark aktarımı (tekrarlanabilir)
  06-cutover.sh                 Faz 3: son fark + konfigürasyon + doğrulama   (--rehearsal: prova)
  07-verify.sh                  doğrulama: schema | config | bulk | delta | counts
  08-finalize.sh                kabul sonrası temizlik
  status.sh                     ilerleme, tahmini bitiş, boyutlar
  zabbix-server/                → d724zbx01'e kopyalanır, root ile çalışır
    10-prepare.sh               paketleri önceden indirir, yedek alır, bağlantıyı dener (kesintisiz)
    11-stop.sh                  Zabbix + frontend'i durdurur (kesinti başlangıcı)
    12-switch.sh                paket değişimi (mysql → pgsql), ayar dosyaları, başlatma
    13-rollback.sh              eski MySQL'e geri dönüş
```

Bütün scriptler tekrar çalıştırılabilir; yarıda kalan iş aynı komutla devam eder. Loglar DB tarafında
`/var/lib/zbxmig/log/`, Zabbix server tarafında `/root/zbx-mig-backup/` altındadır.

## 6. Hazırlık ve toplu aktarım (kesintisiz)

### 6.1 Klon VM hazırlığı

```bash
# klon VM'de, root
hostnamectl set-hostname d724-zabbix-pgdb            # isteğe bağlı, karışıklığı önler
mysql -uroot -p -e "SET PERSIST innodb_buffer_pool_size = 4*1024*1024*1024"   # 24 GB → 4 GB; PG ile aynı makinede OOM olmasın
dnf -y install tmux
```

Mümkünse bu aşamada VM 8 vCPU / 32 GB yapılır. Klona hiçbir Zabbix bileşeni bağlanmamalı.

### 6.2 Dosyalar ve ayarlar

```bash
# kendi makinenizden
scp -r zbx-mig root@<KLON_IP>:/root/
scp -r zbx-mig/zabbix-server root@d724zbx01:/root/zbx-srv

# klon VM'de
cd /root/zbx-mig && cp config.env.example config.env && chmod 600 config.env && vi config.env
```

`config.env` içinde doldurulacaklar:

- `CLONE_MYSQL_PASSWORD`: Zabbix'in DB şifresi (`d724zbx01:/etc/zabbix/zabbix_server.conf` → `DBPassword`).
  Klona `127.0.0.1` ile bağlanılamazsa `CLONE_MYSQL_HOST=localhost` deneyin (socket).
- `PG_ZABBIX_PASSWORD`, `PG_MIG_PASSWORD`: yeni şifreler, örn. `openssl rand -hex 16`. Tek tırnak (`'`) içermesin.
- `PG_STORAGE_SSD`, gerekirse `HK_HISTORY` / `HK_TRENDS`.
- **`PROD_MYSQL_*` ve `ZABBIX_SERVER_IP` bu aşamada BOŞ kalır** (test modu). Kurulum, şema, toplu aktarım
  ve klon doğrulaması canlıya ihtiyaç duymaz. Bu alanlar 6.5'te, ilk `05-catchup.sh` öncesinde doldurulur.

**Canlıya dokunmama kilitleri** (hepsi konteyner ortamında denendi):

| Kilit | Ne yapar |
|---|---|
| `PROD_MYSQL_HOST` boş (test modu) | Canlı için kimlik dosyası hiç yazılmaz; `05-catchup.sh`, `06-cutover.sh`, `07-verify.sh config\|delta` çalışmayı reddeder. Test boyunca canlı MySQL'e sıfır bağlantı gider. |
| Adres kontrolü | `CLONE_MYSQL_HOST` ve `PG_HOST` bu makinenin kendi adresi değilse hiçbir script çalışmaz (yanlışlıkla canlı IP yazılamaz). `PROD_MYSQL_HOST` bu makinenin IP'siyse (script canlı makinede çalıştırılmışsa) durur. |
| Canlı veritabanı algılama | Bu makinedeki MySQL'e bir Zabbix server yazıyorsa (`ha_node.lastaccess` son 2 dk içinde ya da değişiyor) `01`, `02`, `03`, `08` hiçbir şey yapmadan durur. |
| Salt-okunur oturum | Scriptlerin açtığı her MySQL oturumu `transaction_read_only=ON` ile açılır; `INSERT/UPDATE/DELETE/DDL` sunucu tarafında reddedilir (klonda da canlıda da). |
| Yazma hedefi | Bütün yazma/silme komutları yalnızca bu makinedeki PostgreSQL'e gider. |

İsteğe bağlı ek kat (scriptlerden bağımsız, işletim sistemi düzeyinde): test süresince klondan canlıya
giden trafiği tamamen kesmek için `ip route add blackhole 10.0.29.4/32` (kalıcı değildir; geri almak için
`ip route del blackhole 10.0.29.4/32`, 6.5'ten önce kaldırılmalıdır).

### 6.3 Kurulum

```bash
./00-preflight.sh          # [HATA] satırı kalmayana kadar düzeltin (test modunda yalnızca klonu kontrol eder)
./01-install-postgres.sh   # ~5 dk; chrony'yi de kurup başlatır (klonda NTP senkron değildi)
chronyc tracking           # saat senkron mu
./02-create-schema.sh      # ~3 dk; sonunda "klon anı"nı yazar — doğru mu kontrol edin
```

"Klon anı" klonun alındığı zamandır ve klondaki veriden otomatik bulunur. Yanlışsa `config.env`'e
`CLONE_TS=<epoch>` yazıp `RESET=1 ./02-create-schema.sh` çalıştırın.

### 6.4 Faz 1 — toplu aktarım

```bash
tmux new -s bulk
./03-bulk.sh               # 6–16 saat; bağlantı kopsa da tmux içinde sürer
# başka bir terminalde:
watch -n 60 ./status.sh    # ilerleme yüzdesi, kalan süre, disk
```

Kesilirse (reboot, hata) aynı komut kaldığı yerden devam eder. Her tablo bitince klon anından 7 günden
eski chunk'lar sıkıştırılır; disk tepe kullanımı en büyük tablo (`history_uint`) yüklenirken görülür.

### 6.5 Doğrulama ve yakalama

```bash
./07-verify.sh bulk        # tablo başına 300 örnek item: satır sayısı + sağlama toplamı, klon ile birebir olmalı
./07-verify.sh counts      # isteğe bağlı, uzun: tam satır sayıları
```

Buraya kadar canlı sisteme hiç bağlanılmadı. Bundan sonraki adımlar canlı MySQL'den **okur** (yalnızca
`SELECT`); başlamadan önce `config.env`'de `PROD_MYSQL_HOST=10.0.29.4`, `PROD_MYSQL_USER`,
`PROD_MYSQL_PASSWORD` ve `ZABBIX_SERVER_IP` doldurulur (blackhole route eklendiyse kaldırılır):

```bash
./00-preflight.sh              # şimdi canlıyı da kontrol eder; PG_MAX_CONNECTIONS önerisini config.env'e yazın
./01-install-postgres.sh hba   # Zabbix server'a pg_hba izni (reload; restart yok)
./01-install-postgres.sh tune  # yalnızca PG_MAX_CONNECTIONS değiştiyse (PostgreSQL'i yeniden başlatır)
./05-catchup.sh                # ilk geçiş uzun sürer (klonun yaşı kadar veri); mesai dışında çalıştırın
./05-catchup.sh                # ikinci geçiş kısa; sonunda geçiş anı için süre tahmini yazar
```

`05-catchup.sh` canlı MySQL'de aynı anda en fazla `PARALLEL_ONLINE` (2) sorgu çalıştırır, hepsi birincil
anahtar üzerinden kısa `SELECT`'lerdir. İlk geçişte Zabbix'te "Queue" ve history syncer yükünü izleyin;
artış görürseniz `PARALLEL_ONLINE=1` yapın. Geçiş gününe kadar günde bir kez çalıştırmak farkı küçük tutar.

### 6.6 Prova

```bash
# DB tarafı — Zabbix çalışırken geçişin aynısı; sadece süre ölçmek için
./06-cutover.sh --rehearsal
```

Çıktıdaki `[T+… sn]` satırları geçiş anındaki sürelerdir (Bölüm 9'daki tabloya yazın). Zabbix çalıştığı
için konfigürasyon doğrulamasında fark çıkması normaldir. Prova istenildiği kadar tekrarlanabilir,
sonrasında `05-catchup.sh` çalışmaya devam eder.

```bash
# Zabbix server tarafı — çalışan sisteme dokunmaz
cd /root/zbx-srv && cp config.env.example config.env && chmod 600 config.env && vi config.env
./10-prepare.sh
```

`10-prepare.sh` aynı sürümün pgsql paketlerini indirir (kurmaz), `/etc/zabbix` yedeğini alır, paket
değişimini kuru çalıştırır ve PostgreSQL bağlantısını dener. `php-pgsql` ile `psql` istemcisini şimdiden
kurar; bunlar çalışan sistemi etkilemez.

### 6.7 Karar: provadaki makineyle devam mı, taze klon mu?

- **Aynı makineyle devam (önerilen).** Prova temiz geçtiyse bu PostgreSQL zaten canlıya hazır hedeftir:
  toplu veri doğrulanmış, yakalama ile güncel tutuluyor, geçişte konfigürasyon baştan kopyalanıyor.
  Yeniden klonlamak ve 6–16 saatlik aktarımı tekrarlamak gerekmez. Proje 1–2 gün kısalır.
- **Taze klon.** Provada elle müdahale gerektiyse ya da test klonu çok eskiyse: canlı DB yeniden
  klonlanır, Bölüm 6 baştan uygulanır (aynı makinede `RESET=1 ./02-create-schema.sh` ile de olur).

## 7. Geçiş günü

### 7.1 Önceki gün

- [ ] Müşteri duyuruları gitti, pencere onaylı (`03-musteri-duyuru-sablonu.md`)
- [ ] Zabbix'te bakım periyodu tanımlı (pencere + 1 saat, tüm host grupları, "With data collection")
- [ ] `d724zbx01` ve canlı DB VM'in son yedekleri başarılı (müşteri teyidi)
- [ ] `./05-catchup.sh` çalıştı, `./status.sh` temiz, `failed-units.log` boş
- [ ] `./00-preflight.sh` temiz (proxy'ler bağlı, saat farkı yok)
- [ ] vCenter erişimi olan kişi ve müşteri tarafı irtibat kişisi pencere boyunca hazır
- [ ] Zabbix sürümü hâlâ 7.4.13 (`rpm -q zabbix-server-mysql`)

### 7.2 Geçiş

```bash
# T−60 ve T−10, DB makinesi
cd /root/zbx-mig && ./05-catchup.sh

# T0, Zabbix server
cd /root/zbx-srv && ./11-stop.sh

# T+5: vCenter'dan d724zbx01 snapshot'ı (bellek dahil etmeyin)

# T+7, DB makinesi
./06-cutover.sh
```

`06-cutover.sh` önce canlı MySQL'de Zabbix bağlantısı kalmadığını kontrol eder. Bir izleme aracı bağlantısı
yüzünden duruyorsa listeyi görüp `--force` ile devam edebilirsiniz. Sonunda iki sonuçtan biri çıkar:

- `GECIS TAMAM — simdi Zabbix server uzerinde: ./12-switch.sh` → devam.
- `DOGRULAMA BASARISIZ` → Zabbix'i PostgreSQL'e **bağlamayın**. Büyük olasılıkla canlı MySQL'e hâlâ yazan
  bir şey vardır; durdurup `./06-cutover.sh` komutunu yeniden çalıştırın. Çözülmezse geri dönüş.

```bash
# T+20, Zabbix server
./12-switch.sh
```

Paketleri değiştirir, `zabbix_server.conf` ve `zabbix.conf.php` dosyalarını yeni DB'ye çevirir (mevcut
tuning ayarları korunur), servisleri başlatır, açılışı log'dan doğrular ve kesinti süresini yazar.

### 7.3 Geri dönüş

```bash
# Zabbix server
./13-rollback.sh --yes
```

Paketler ve ayar dosyaları yedekten geri gelir, Zabbix eski MySQL ile açılır (testte 20 sn; 2–5 dk
öngörün). Canlı MySQL'e geçiş boyunca hiç yazılmadığı için kaldığı yerden devam eder. Paket geri dönüşü
de başarısız olursa son çare T+5'te alınan vCenter snapshot'ıdır.

Geri dönüşten sonra yeniden denemek için baştan başlamak gerekmez: sorun giderilir, yeni bir pencerede
`11-stop.sh → 06-cutover.sh → 12-switch.sh` tekrarlanır (test edildi).

### 7.4 Kontrol listesi (T+25)

- [ ] Reports → System information: "Zabbix server is running: Yes", veritabanı/TimescaleDB uyarısı yok
- [ ] Monitoring → Latest data: yeni değerler geliyor; bir grafikte kesinti öncesi geçmiş görünüyor
- [ ] Administration → Proxies: 16 proxy'nin hepsi bağlı, "last seen" güncel
- [ ] Administration → Queue: kuyruk eriyor (proxy tamponları 5–30 dk içinde boşalır)
- [ ] Test bildirimi gidiyor (Alerts → Media types → Test)
- [ ] `tail -f /var/log/zabbix/zabbix_server.log`: tekrarlayan hata yok
- [ ] API kullanan entegrasyonlar (Grafana, ticket sistemi vb.) çalışıyor

## 8. Geçiş sonrası

**İlk 24 saat**

- Zabbix log'u ve PostgreSQL log'u (`/var/lib/pgsql/17/data/log/`) izlenir.
- Sıkıştırma işleri kontrol edilir (Zabbix server ilk açılışta kendisi tanımlar):
  ```bash
  sudo -u postgres psql -d zabbix -c "SELECT j.hypertable_name, s.last_run_status, s.last_successful_finish
    FROM timescaledb_information.jobs j JOIN timescaledb_information.job_stats s USING (job_id)
    WHERE j.proc_name = 'policy_compression'"
  ```
- Bakım periyodu kaldırılır. vCenter snapshot'ı 24–48 saat içinde **silinir** (uzun süre kalan snapshot
  diski büyütür ve yavaşlatır).
- Eski canlı MySQL VM'i: ilk gün açık ama kullanılmadan bekler (hızlı geri dönüş için), sonra kapatılır.

**İlk hafta**

- Veritabanı izleme şablonu PostgreSQL'e çevrilir; yeni DB VM yedekleme işine eklenir.
- Disk kullanımı ve chunk sayıları `./status.sh` ile izlenir.

**Kabul sonrası (≈1 hafta)**

```bash
cd /root/zbx-mig && ./08-finalize.sh --yes
```

Geçiş şeması ve geçici superuser silinir, klondaki MySQL durdurulup devre dışı bırakılır (verisi silinmez),
şifre dosyaları temizlenir. Çıktıdaki elle yapılacaklar: `config.env` silme, bellek artık yalnızca
PostgreSQL'in olduğu için `./01-install-postgres.sh tune`, eski MySQL verisinin silinmesi (236 GB),
eski canlı MySQL VM'inin 1–2 hafta kapalı saklanıp silinmesi.

## 9. Prova ölçüm tablosu

Provadan sonra doldurun; müşteriye verilen pencere bu sayılarla teyit edilir.

| Ölçüm | Kaynak | Değer |
|---|---|---|
| Toplu aktarım toplam süresi | `03-bulk.sh` son satırı | |
| `history_uint` hızı (satır/sn) | `03-bulk.sh` çıktısı | |
| PostgreSQL boyutu (sıkıştırma sonrası) | `status.sh` | |
| İkinci yakalama süresi | `05-catchup.sh` son satırları | |
| Prova: aktarım bitti `[T+ sn]` | `06-cutover.sh --rehearsal` | |
| Prova: doğrulama bitti `[T+ sn]` | aynı | |
| Prova: toplam süre | aynı | |
| Canlıda tepe bağlantı sayısı | `00-preflight.sh` | |

Provanın toplam süresi 15 dakikayı aşıyorsa geçişten önce konuşalım: `PARALLEL_CUTOVER` artırılabilir,
VM'e CPU eklenebilir ya da `OVERLAP` küçültülebilir.

## 10. Sorun giderme

| Belirti | Yapılacak |
|---|---|
| `03-bulk.sh` yarıda kaldı | Aynı komutu yeniden çalıştırın; biten birimler atlanır |
| "N birim basarisiz" | `/var/lib/zbxmig/log/failed-units.log` — MySQL/PG hata mesajı orada |
| Disk doluyor | `./status.sh`; `./04-compress.sh` elle çalıştırılabilir |
| Yakalama sırasında canlıda yük | `PARALLEL_ONLINE=1` |
| `07-verify.sh delta` fark veriyor (Zabbix çalışırken) | Normal: canlıya o sırada veri yazılıyor. Geçişte Zabbix kapalıyken birebir olmalı |
| `06-cutover.sh`: "canli MySQL hala kullaniliyor" | Listelenen bağlantıyı kapatın; Zabbix dışı bir izleme bağlantısıysa `--force` |
| `12-switch.sh`: Zabbix açılmadı | `tail -100 /var/log/zabbix/zabbix_server.log`; bağlantı hatasıysa `pg_hba.conf` / şifre / 5432 erişimi. Çözülmüyorsa `./13-rollback.sh --yes` |
| Her şeye baştan başlamak | `RESET=1 ./02-create-schema.sh` (PostgreSQL'e aktarılan tüm veri silinir) |

## 11. Neler test edildi

Scriptlerin tamamı aynı sürümlerle (MySQL 8.4, Zabbix 7.4.13, PostgreSQL 17, TimescaleDB 2.28.3,
AlmaLinux 10 ve Oracle Linux 9) kurulan bir konteyner ortamında uçtan uca çalıştırıldı:

- Kurulum, şema, toplu aktarım, sıkıştırma, iki yakalama geçişi, prova, gerçek geçiş, switch, geri dönüş,
  yeniden geçiş ve temizlik.
- Veri doğruluğu: 198 konfigürasyon tablosu birebir; ondalıklı değerler bit düzeyinde aynı (uç değerler
  dahil); sekme, satır sonu, ters bölü, emoji ve ikili veri içeren metinler aynı.
- Aktarım ortasında MySQL bağlantısı kesildiğinde birimin geri alındığı ve yeniden denendiği.
- Canlıya dokunmama kilitleri: test modunda (`PROD_MYSQL_*` boş) kurulum + şema + toplu aktarım +
  doğrulama boyunca canlı MySQL'in bağlantı kaydında (general_log) klondan gelen sıfır bağlantı; yanlış
  adres, canlı makinede çalıştırma ve "klon"a Zabbix yazması durumlarında scriptlerin durduğu; salt-okunur
  oturumda her yazma/DDL denemesinin reddedildiği. Gerçek geçişin tamamında canlıya giden komutlar
  yalnızca `SELECT` ve iki oturum ayarı (`SET SESSION transaction_read_only`, `net_write_timeout`).
- Zabbix server'ın taşınan veritabanıyla açıldığı, TimescaleDB ve önceden sıkıştırılmış chunk'ları
  kabul ettiği, sıkıştırma işlerini kendisinin tanımladığı ve işlerin hatasız çalıştığı; frontend ve
  API'nin çalıştığı; yeni verinin PostgreSQL'e yazıldığı.

Test edilemeyenler: gerçek veri hacmi ve gerçek donanımdaki hız (test verisi 24 milyon satırdı; süreler
bu yüzden tahmin), 16 proxy'nin yeniden bağlanma davranışı, müşterinin gerçek `zabbix_server.conf` /
nginx / php-fpm ayarları. Provanın amacı bunları kesintiden önce görmektir.
