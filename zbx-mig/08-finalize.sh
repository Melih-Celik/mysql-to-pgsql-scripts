#!/usr/bin/env bash
# Gecis KABUL EDILDIKTEN sonra (Zabbix PostgreSQL ile birkac gun sorunsuz calisinca) temizlik.
# - gecis takip semasi (zbxmig) ve gecici superuser silinir, pg_hba satiri kaldirilir, sifre dosyalari silinir
# - bu makinedeki (klon) MySQL durdurulur ve devre disi birakilir (veri SILINMEZ)
#   ./08-finalize.sh --yes
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $EUID == 0 ]] || die "root olarak calistirin"
[[ ${1:-} == --yes ]] || die "bu islem gecis araclarini kaldirir; onay icin: $0 --yes"
init_workdir
PGBIN=/usr/pgsql-$PG_VERSION/bin; PGDATA=${PGDATA_DIR:-/var/lib/pgsql/$PG_VERSION/data}

[[ $(pgq "SELECT value_str FROM settings WHERE name = 'db_extension'") == timescaledb ]] || die "gecis tamamlanmamis gorunuyor (settings.db_extension)"
step "zbxmig semasi ve rolu siliniyor"
psu -d "$PG_DB" -c "DROP SCHEMA IF EXISTS zbxmig CASCADE"
psu -d postgres -c "DROP ROLE IF EXISTS \"$PG_MIG_USER\""
sed -i "/^host    all    $PG_MIG_USER    /d" "$PGDATA/pg_hba.conf"
psu -d postgres -c "SELECT pg_reload_conf()" >/dev/null

step "Bu makinedeki MySQL durduruluyor (veri dizini yerinde kalir)"
for svc in mysqld mysql mariadb; do
  if systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc"; then systemctl disable --now "$svc" && log "    $svc durduruldu"; fi
done

step "Gecici dosyalar"
rm -f "$WORK_DIR"/my-*.cnf "$WORK_DIR/pgpass"; rm -rf "$WORK_DIR/units" "$WORK_DIR/plan" "$WORK_DIR/verify"
log "    loglar duruyor: $WORK_DIR/log"

cat >&2 <<TXT

TEMIZLIK TAMAM. Elle yapilacaklar:
  1. config.env dosyasini silin (sifre iceriyor):  shred -u $ZBXMIG_CONF
  2. Bellek artik sadece PostgreSQL'in: gerekiyorsa VM kaynaklarini guncelleyip  ./01-install-postgres.sh tune  (config.env silinmeden once)
  3. Disk kazanmak icin eski MySQL verisi:  dnf remove 'mysql-community-*' && rm -rf /var/lib/mysql   (geri donus ihtiyaci kalmadiginda)
  4. Eski canli MySQL VM'i: kapali halde 1-2 hafta saklayin, sonra silin.
  5. Yedekleme: PostgreSQL icin yedek isi tanimlayin (VM yedegi ve/veya pg_dump / pgBackRest).
  6. Zabbix'te veritabani izleme: "MySQL by Zabbix agent 2" yerine "PostgreSQL by Zabbix agent 2" sablonu.
TXT
