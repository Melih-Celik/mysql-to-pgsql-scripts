# Zabbix Veritabanı Geçiş Planı: MySQL → PostgreSQL

| | |
|---|---|
| Hazırlayan | [Firma Adı] |
| Müşteri | [Müşteri Adı] |
| Belge tarihi | [GG.AA.YYYY] |
| Planlanan geçiş | [GG.AA.YYYY, SS:DD–SS:DD] |
| Planlı kesinti | 30–40 dakika öngörülüyor, **en fazla 60 dakika** |

## 1. Amaç ve kapsam

Zabbix izleme altyapısının veritabanı MySQL'den PostgreSQL'e (TimescaleDB eklentisiyle) taşınacaktır.

**Kapsam içinde**

- Zabbix veritabanının tamamı: host, şablon, tetikleyici, kullanıcı, dashboard ve diğer tüm
  konfigürasyon; problem ve olay geçmişi; tüm geçmiş ölçüm verisi (history ve trends); denetim kayıtları.
- Zabbix server ve web arayüzünün yeni veritabanına bağlanması.

**Kapsam dışında**

- Zabbix sürüm yükseltmesi (sürüm 7.4.13 olarak kalır).
- Zabbix proxy'leri ve agent'lar (herhangi bir değişiklik yapılmaz).
- İzlenen sistemler (hiçbir şekilde etkilenmez).

## 2. Mevcut ve hedef durum

| | Mevcut | Hedef |
|---|---|---|
| Veritabanı | MySQL 8.4 | PostgreSQL 17 + TimescaleDB 2.28 |
| Veritabanı sunucusu | Mevcut MySQL VM | Yeni VM (mevcut VM'in klonu üzerine kurulur) |
| Veri boyutu | ≈ 236 GB | Sıkıştırma sayesinde daha küçük (bkz. Bölüm 8) |
| Zabbix server | `d724zbx01`, 7.4.13 | Aynı sunucu, aynı sürüm |
| İzleme yükü | ≈ 2.200 değer/sn, 2.149 host, 16 proxy | Aynı |

TimescaleDB ile eski ölçüm verileri otomatik sıkıştırılır ve süresi dolan veri tek seferde, sistemi
yormadan silinir. Bu, mevcut veri hacminde hem disk kullanımını hem de veritabanı bakım yükünü azaltır.

## 3. Yöntem

Veri hacmi bir kesinti penceresine sığmayacak kadar büyük olduğu için geçiş üç aşamada yapılır.
İlk iki aşamada Zabbix kesintisiz çalışmaya devam eder.

| Aşama | Ne yapılır | Süre | Kesinti |
|---|---|---|---|
| 1. Toplu aktarım | Veritabanı sunucusunun klonu üzerinde tüm geçmiş veri PostgreSQL'e aktarılır. Canlı sisteme yük binmez. | 6–16 saat (arka planda) | Yok |
| 2. Yakalama | Klonun alındığı andan sonra biriken veri canlı veritabanından yalnızca okunarak eklenir. Geçiş gününe kadar tekrarlanır. | Her seferinde 5–40 dk | Yok |
| 3. Geçiş | Zabbix durdurulur, son birkaç dakikanın verisi ve güncel konfigürasyon aktarılır, doğrulanır, Zabbix yeni veritabanıyla açılır. | 30–40 dk | **Var** |

Canlı MySQL veritabanında geçiş boyunca hiçbir değişiklik yapılmaz; yalnızca okunur. Bu sayede sorun
halinde eski yapıya dakikalar içinde dönülebilir.

## 4. Takvim

| Gün | İş | Sorumlu |
|---|---|---|
| G−7 … G−5 | Hazırlık, PostgreSQL kurulumu, toplu aktarım (gece) | [Firma Adı] |
| G−5 … G−4 | Doğrulama, yakalama, geçiş provası; kesinti süresinin ölçülerek teyidi | [Firma Adı] |
| G−4 | Kesin tarih/saat onayı | [Müşteri Adı] |
| G−3 | Kullanıcılara ve ilgili taraflara duyuru | [Müşteri Adı] |
| G−1 | Hatırlatma duyurusu, son kontroller, yedek teyidi | Birlikte |
| **G** | **Geçiş (planlı kesinti)** | Birlikte |
| G+1 | Yakın izleme, geçici snapshot'ın silinmesi | [Firma Adı] |
| G+7 | Kabul, temizlik, eski veritabanı sunucusunun kapatılması | Birlikte |

Geçiş provası gerçek veriyle yapılır ve kesinti adımlarının süresi ölçülür. Ölçülen süre öngörülen
pencereyi aşıyorsa geçiş tarihi onaylanmadan önce bilgi verilir.

## 5. Kesinti penceresi ve etkisi

**Planlanan pencere:** [GG.AA.YYYY, SS:DD–SS:DD] (60 dakika). Öngörülen fiilî kesinti 30–40 dakikadır.

Kesinti süresince:

- Zabbix web arayüzü ve API'si kapalıdır. Dashboard'lar, raporlar ve Zabbix API'sini kullanan
  entegrasyonlar (Grafana, çağrı/ticket sistemi vb.) çalışmaz.
- **Alarm üretilmez, bildirim gönderilmez.** Bu sürede oluşan arızalar Zabbix açıldıktan sonra tespit edilir.
- Proxy üzerinden izlenen sistemlerin verisi proxy'lerde biriktirilir ve Zabbix açıldığında eksiksiz aktarılır.
- Doğrudan Zabbix server tarafından izlenen sistemlerde kesinti süresi kadar grafik boşluğu oluşur.
- İzlenen sunucular, ağ cihazları ve uygulamalar **etkilenmez**; yalnızca izleme hizmeti durur.

Zabbix açıldıktan sonraki ilk 15–30 dakikada biriken verinin işlenmesi nedeniyle gecikmeli alarmlar
görülebilir. Toplu bildirim oluşmaması için geçiş penceresini kapsayan bir bakım periyodu tanımlanacaktır.

## 6. Veri bütünlüğü ve doğrulama

- Toplu aktarımdan sonra kaynak ve hedef, örnek item'lar üzerinde satır sayısı ve sağlama toplamıyla
  karşılaştırılır.
- Geçiş anında, Zabbix kapalıyken, tüm konfigürasyon tabloları (yaklaşık 200 tablo) kaynakla **kolon
  bazında sağlama toplamı** alınarak birebir karşılaştırılır. Son aktarılan ölçüm verisi de ayrıca doğrulanır.
- Doğrulama başarısız olursa Zabbix yeni veritabanına bağlanmaz; sorun giderilir ya da geri dönülür.
- Geçişe kadar yapılan tüm konfigürasyon değişiklikleri (yeni host, şablon, kullanıcı vb.) taşınır;
  değişiklik dondurma gerekmez. Yalnızca Zabbix sürümü proje boyunca değiştirilmemelidir.

## 7. Riskler ve önlemler

| Risk | Etki | Önlem |
|---|---|---|
| Geçişin öngörülenden uzun sürmesi | Kesintinin uzaması | Süreler önceden provayla ölçülür. T+40. dakikada karar noktası: sorun varsa geri dönülür, toplam kesinti 60 dakikayı aşmaz |
| Yeni veritabanıyla beklenmeyen sorun | İzleme hizmetinin aksaması | Eski MySQL değiştirilmeden bekler; geri dönüş 5 dakika. Ek olarak Zabbix server'ın VMware snapshot'ı alınır |
| Geri dönüş yapılması | Yeni veritabanıyla çalışılan sürenin verisi eski yapıya taşınmaz (grafikte boşluk) | Geri dönüş kararı ilk saatlerde verilir |
| Kesinti sırasında izleme körlüğü | Bu sürede oluşan arızalar gecikmeli fark edilir | Pencere düşük yoğunluklu saatte seçilir; kritik sistemler için müşteri tarafında geçici manuel takip |
| Açılışta toplu bildirim | Gereksiz alarm/e-posta | Bakım periyodu tanımlanır |
| Proxy'lerde tampon süresinin aşılması | Proxy arkasındaki sistemlerde veri boşluğu | Proxy tampon süresi (varsayılan 1 saat) önceden kontrol edilir, gerekirse artırılır |
| Kesinti sırasında gelen SNMP trap'leri | Bu trap'ler kaybolur | Duyuruda belirtilir |

## 8. Müşteri tarafından verilmesi gereken kararlar

**8.1 Geçmiş veri saklama süresi.** TimescaleDB ile saklama süresi item/şablon bazında değil, **tüm
sistem için tek değer** olarak uygulanır (sıkıştırılmış verinin silinebilmesi için bu zorunludur).
Mevcut global değerler history için 90 gün, trends için 365 gündür; ancak bugün item'ların çoğu kendi
(daha kısa) süresini kullanmaktadır.

| Seçenek | History (ayrıntılı veri) | Trends (saatlik özet) | Tahmini disk kullanımı |
|---|---|---|---|
| A | 31 gün | 365 gün | ≈ 200–230 GB |
| B | 90 gün | 365 gün | ≈ 290–320 GB |

Mevcut disk (772 GB) iki seçenek için de yeterlidir. Seçim: [ ] A   [ ] B   [ ] Diğer: ……

**8.2 Geçiş tarihi ve saati.** İzleme körlüğünün en az etkileyeceği zaman dilimi. Öneri: [gün, saat].

**8.3 Yeni veritabanı sunucusunun kaynakları.** Öneri 8 vCPU / 32 GB RAM (mevcut 4 vCPU / 23 GB).
Aktarım süresini kısaltır ve PostgreSQL için çalışma payı bırakır.

## 9. Müşteriden beklenenler

- [ ] Geçiş tarih ve saatinin yazılı onayı
- [ ] Bölüm 8'deki kararlar
- [ ] Zabbix'i kullanan iç ekiplere ve hizmet verilen müşterilere kesinti duyurusu (şablonlar ekte)
- [ ] Zabbix server ve veritabanı sunucularının güncel yedeğinin alındığının teyidi
- [ ] MySQL veritabanına doğrudan bağlanan başka sistem olup olmadığının bildirilmesi (Grafana veri
      kaynağı, rapor scriptleri, yedekleme işleri vb.)
- [ ] Zabbix server ile yeni veritabanı sunucusu arasında 5432/tcp erişimi (arada güvenlik duvarı varsa)
- [ ] Geçiş penceresinde VMware vCenter yetkisi olan bir kişinin hazır bulunması (snapshot için)
- [ ] Geçiş sırasında ulaşılabilir bir irtibat kişisi ve geçiş sonrası kontrol için bir Zabbix kullanıcısı
- [ ] Proje boyunca Zabbix sürümünün güncellenmemesi
- [ ] Geçiş sonrası: yeni veritabanı sunucusunun yedekleme planına eklenmesi

## 10. Kabul ölçütleri

Geçiş aşağıdaki koşullar sağlandığında tamamlanmış sayılır:

1. Konfigürasyon tablolarının kaynakla birebir doğrulanmış olması (doğrulama raporu paylaşılır).
2. Zabbix arayüzünde "Zabbix server is running: Yes" ve veritabanı uyarısı bulunmaması.
3. Tüm proxy'lerin bağlı olması ve yeni verinin akması.
4. Kesinti öncesine ait geçmiş verinin grafiklerde görünmesi.
5. Test bildiriminin başarıyla iletilmesi.
6. Toplam kesintinin 60 dakikayı aşmaması.

## 11. Geçiş sonrası

- İlk 24 saat sistem yakından izlenir; geçici VMware snapshot'ı 24–48 saat içinde silinir.
- Eski MySQL sunucusu 1–2 hafta kapalı halde saklanır, kabulden sonra silinir.
- Veritabanı izleme şablonu ve yedekleme işleri PostgreSQL'e göre güncellenir.
- İleride yapılacak Zabbix sürüm yükseltmelerinde TimescaleDB sürüm uyumluluğu ayrıca kontrol edilmelidir.

## 12. İletişim

| Rol | Ad | Telefon | E-posta |
|---|---|---|---|
| Geçiş sorumlusu ([Firma Adı]) | | | |
| Müşteri irtibat kişisi | | | |
| vCenter yetkilisi | | | |
