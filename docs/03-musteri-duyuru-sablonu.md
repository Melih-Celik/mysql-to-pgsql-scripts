# Ön Bilgilendirme: Müşteri Kontrol Listesi ve Duyuru Şablonları

Köşeli parantez içindeki alanlar doldurulacaktır. Şablon 1–4 müşterinin kendi kullanıcılarına ve hizmet
verdiği müşterilere göndereceği metinlerdir; Şablon 5 müşterinin operasyon/NOC ekibi içindir.

## A. Müşteri kontrol listesi

**En geç 3 iş günü önce**

- [ ] Geçiş tarih/saatini yazılı onaylayın.
- [ ] Zabbix'e bağlı müşterilerinize ve iç ekiplere kesinti duyurusunu gönderin (Şablon 1).
- [ ] Zabbix alarmlarına bağlı süreçleri gözden geçirin: nöbet/on-call ekibi, çağrı açan entegrasyonlar,
      SLA raporları. Kesinti süresince alarm gelmeyeceğini ilgili ekiplere bildirin.
- [ ] MySQL veritabanına doğrudan bağlanan sistem varsa bildirin (Grafana, rapor, yedekleme scripti).
- [ ] Saklama süresi kararını iletin (geçiş planı Bölüm 8.1).

**1 gün önce**

- [ ] Zabbix server ve veritabanı sunucusunun son yedeğinin **başarılı** olduğunu teyit edin.
- [ ] Hatırlatma duyurusunu gönderin (Şablon 2).
- [ ] Geçiş penceresinde vCenter yetkilisinin ve irtibat kişisinin hazır olacağını teyit edin.
- [ ] Pencereye denk gelen başka planlı çalışma (ağ, depolama, VMware bakımı) olmadığını teyit edin.
- [ ] Kritik sistemler için kesinti süresince geçici takip yöntemi belirleyin (ör. nöbetçi tarafından elle kontrol).

**Geçiş sırasında**

- [ ] Kesinti başlamadan hemen önce NOC/operasyon ekibini bilgilendirin (Şablon 5).
- [ ] İstendiğinde vCenter'da Zabbix server VM'inin snapshot'ını alın (bellek dahil edilmeden).
- [ ] Zabbix açıldıktan sonra kendi kullanıcınızla girip kontrol edin: dashboard'lar, son veriler, bir test bildirimi.

**Geçişten sonra**

- [ ] "Tamamlandı" duyurusunu gönderin (Şablon 3).
- [ ] Zabbix API kullanan entegrasyonlarınızı (Grafana, ticket sistemi) kontrol edin.
- [ ] Yeni veritabanı sunucusunu yedekleme planına ekleyin; eski MySQL yedekleme işini kaldırın.
- [ ] 24–48 saat içinde snapshot'ın silindiğini teyit edin.

## B. Şablon 1 — Planlı kesinti duyurusu (en geç 3 iş günü önce)

**Konu:** Planlı Bakım: İzleme Sistemi (Zabbix) — [GG.AA.YYYY, SS:DD–SS:DD]

Sayın İlgili,

İzleme altyapımızda planlı bir veritabanı iyileştirme çalışması yapılacaktır.

| | |
|---|---|
| Tarih | [GG.AA.YYYY, Gün] |
| Saat | [SS:DD] – [SS:DD] (Türkiye saati) |
| Öngörülen kesinti | 30–40 dakika (en fazla 60 dakika) |
| Etkilenen hizmet | İzleme sistemi (Zabbix): web arayüzü, alarm ve bildirimler, API |

**Çalışma süresince:**

- İzleme arayüzüne ve dashboard'lara erişilemeyecektir.
- Alarm üretilmeyecek, e-posta/SMS/çağrı bildirimi gönderilmeyecektir.
- İzleme verisini kullanan rapor ve entegrasyonlar geçici olarak çalışmayacaktır.

**Etkilenmeyenler:**

- İzlenen sunucu, ağ cihazı ve uygulamalarınız çalışmaya devam eder; çalışma yalnızca izleme
  hizmetini kapsamaktadır.
- Mevcut izleme tanımları ve geçmiş veriler korunacaktır.

Çalışma sonrasında, kesinti süresince biriken verinin işlenmesi nedeniyle ilk 30 dakika içinde
gecikmeli bildirimler alabilirsiniz. Bu süre içinde kritik sistemlerinizde bir sorun yaşarsanız lütfen
doğrudan [telefon / e-posta] üzerinden bize ulaşınız.

Çalışmanın tamamlandığı ayrıca bildirilecektir. Anlayışınız için teşekkür ederiz.

[Ad Soyad]
[Unvan, Firma]
[İletişim]

## C. Şablon 2 — Hatırlatma (1 gün önce)

**Konu:** Hatırlatma: Planlı Bakım — İzleme Sistemi (Zabbix) — [GG.AA.YYYY, SS:DD]

Sayın İlgili,

Daha önce duyurduğumuz izleme sistemi bakım çalışması **[GG.AA.YYYY] günü [SS:DD]–[SS:DD]** saatleri
arasında yapılacaktır. Bu süre içinde izleme arayüzü kapalı olacak, alarm ve bildirim gönderilmeyecektir.
İzlenen sistemleriniz çalışmadan etkilenmeyecektir.

Çalışma süresince acil durumlar için: [telefon / e-posta].

[Ad Soyad], [Firma]

## D. Şablon 3 — Tamamlandı duyurusu

**Konu:** Tamamlandı: Planlı Bakım — İzleme Sistemi (Zabbix)

Sayın İlgili,

İzleme sistemi bakım çalışması **[SS:DD]** itibarıyla başarıyla tamamlanmıştır. Hizmet
[SS:DD]–[SS:DD] arasında ([..] dakika) kesintiye uğramıştır.

- İzleme arayüzü, alarm ve bildirimler normal çalışmaktadır.
- Tüm izleme tanımları ve geçmiş veriler korunmuştur.
- Kesinti süresine ait grafiklerde kısa bir boşluk görülebilir.
- İlk 30 dakika içinde gecikmeli bildirimler ulaşmış olabilir; bunlar kesinti süresinde biriken verilerden kaynaklanır.

Bir aksaklık fark ederseniz lütfen [telefon / e-posta] üzerinden bildiriniz.

[Ad Soyad], [Firma]

## E. Şablon 4 — Erteleme / geri dönüş duyurusu (gerekirse)

**Konu:** Bilgilendirme: İzleme Sistemi (Zabbix) Bakım Çalışması Ertelendi

Sayın İlgili,

[GG.AA.YYYY] tarihinde başlanan izleme sistemi bakım çalışması, doğrulama adımlarında tespit edilen bir
uyumsuzluk nedeniyle tamamlanmadan durdurulmuş ve sistem **önceki yapısına geri alınmıştır**. İzleme
hizmeti [SS:DD] itibarıyla normal çalışmaktadır; izleme tanımlarında ve geçmiş verilerde kayıp yoktur.
[SS:DD]–[SS:DD] arasına ait grafiklerde boşluk görülebilir.

Çalışmanın yeni tarihi ayrıca duyurulacaktır.

[Ad Soyad], [Firma]

## F. Şablon 5 — Operasyon / NOC ekibi iç bilgilendirmesi

**Konu:** [GG.AA.YYYY SS:DD] Zabbix veritabanı geçişi — operasyon notu

- **[SS:DD]–[SS:DD] arasında Zabbix kapalı.** Alarm gelmemesi normaldir; bu süre içinde kritik sistemleri
  [yöntem: elle kontrol / alternatif araç] ile takip edin.
- Pencere için Zabbix'te bakım periyodu tanımlıdır; açılıştan sonraki ilk saatte bildirimler bastırılır.
  Bu sürede problemleri görmek için Monitoring → Problems ekranında "Show suppressed problems" işaretlenmelidir.
- Açılıştan sonra 15–30 dakika boyunca "Queue" yüksek ve veriler gecikmeli olabilir; proxy'lerde
  biriken veri aktarılıyor demektir.
- Proxy üzerinden izlenen sistemlerin verisi eksiksiz gelir. Doğrudan izlenen sistemlerde kesinti kadar
  grafik boşluğu olur. Kesinti sırasındaki SNMP trap'leri alınamaz.
- Zabbix adresi, kullanıcılar, dashboard'lar ve API token'ları **değişmez**. Açık oturumlar korunur.
- Açılıştan sonra beklenmeyen bir durum görürseniz (host'lar "unavailable", veri gelmiyor, bildirim
  gitmiyor): [geçiş sorumlusu, telefon].
- Sorun halinde sistem eski veritabanına geri alınabilir; bu durumda ayrıca bilgi verilecektir.
