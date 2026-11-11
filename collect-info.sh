#!/usr/bin/env bash
# Zabbix MySQL -> PostgreSQL gecisi icin envanter toplama (SALT-OKUNUR, hicbir seyi degistirmez).
#
# Kullanim:
#   DB makinesinde (once TEST kopyasinda):  ./collect-info.sh db -uroot -p        > db-info.txt
#   Zabbix server'da:                       sudo ./collect-info.sh server         > server-info.txt
#
# "db" modunda ilk arguman sonrasi her sey mysql client'a aynen gecirilir (-u, -p, -h, -S ...).
# Veritabani adi "zabbix" degilse: ZBX_DB=baska_ad ./collect-info.sh db ...
set -u

section() { printf '\n######## %s ########\n' "$*"; }

sys_info() {
  section "OS"
  cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|VERSION_ID)='
  uname -r
  section "CPU / RAM"
  echo "vCPU: $(nproc)"
  free -h
  section "Disk"
  df -hT -x tmpfs -x devtmpfs
  lsblk -o NAME,SIZE,TYPE,ROTA,MOUNTPOINT 2>/dev/null
  section "Saat dilimi"
  timedatectl 2>/dev/null | grep -Ei 'time zone|synchronized' || date
  section "Internet / repo erisimi"
  for url in https://download.postgresql.org https://repo.zabbix.com https://packagecloud.io; do
    if curl -sI --max-time 5 "$url" >/dev/null 2>&1; then echo "OK    $url"; else echo "YOK   $url"; fi
  done
  section "SELinux / firewall"
  getenforce 2>/dev/null || echo "getenforce yok"
  systemctl is-active firewalld ufw 2>/dev/null | paste -sd' '
}

db_info() {
  sys_info
  section "MySQL paketleri / araclar"
  (rpm -qa 2>/dev/null | grep -Ei 'mysql|mariadb|percona|postgres|pgloader|timescale') \
    || (dpkg -l 2>/dev/null | grep -Ei 'mysql|mariadb|percona|postgres|pgloader|timescale' | awk '{print $2, $3}')
  for b in mysql mysqldump mydumper psql pgloader; do
    printf '%-10s %s\n' "$b" "$(command -v $b 2>/dev/null || echo yok)"
  done

  section "MySQL sorgulari (db: ${ZBX_DB:=zabbix})"
  mysql "$@" --force --table "$ZBX_DB" <<'SQL'
SELECT 'sunucu' AS bolum, @@version AS version, @@version_comment AS dagitim, @@datadir AS datadir,
       @@character_set_server AS charset, @@collation_server AS collation,
       ROUND(@@innodb_buffer_pool_size/1024/1024/1024,1) AS buffer_pool_gb;

SELECT 'zabbix dbversion' AS bolum, d.* FROM dbversion d;

SELECT 'toplam boyut' AS bolum,
       ROUND(SUM(data_length+index_length)/1024/1024/1024,2) AS toplam_gb,
       ROUND(SUM(data_length)/1024/1024/1024,2) AS veri_gb,
       ROUND(SUM(index_length)/1024/1024/1024,2) AS index_gb,
       COUNT(*) AS tablo_sayisi
  FROM information_schema.tables WHERE table_schema = DATABASE();

SELECT table_name AS en_buyuk_30_tablo, engine, table_rows AS yaklasik_satir,
       ROUND(data_length/1024/1024/1024,2) AS veri_gb,
       ROUND(index_length/1024/1024/1024,2) AS index_gb, table_collation
  FROM information_schema.tables WHERE table_schema = DATABASE()
 ORDER BY data_length+index_length DESC LIMIT 30;

SELECT engine, table_collation, COUNT(*) AS tablo
  FROM information_schema.tables WHERE table_schema = DATABASE() GROUP BY engine, table_collation;

SELECT table_name AS partition_li_tablo, COUNT(*) AS partition_sayisi,
       MIN(partition_name) AS ilk, MAX(partition_name) AS son
  FROM information_schema.partitions
 WHERE table_schema = DATABASE() AND partition_name IS NOT NULL GROUP BY table_name;

SELECT table_name AS history_trends_indexleri, index_name,
       GROUP_CONCAT(column_name ORDER BY seq_in_index) AS kolonlar
  FROM information_schema.statistics
 WHERE table_schema = DATABASE() AND (table_name LIKE 'history%' OR table_name LIKE 'trends%')
 GROUP BY table_name, index_name;

SELECT table_name, column_name, column_type
  FROM information_schema.columns
 WHERE table_schema = DATABASE() AND table_name IN ('history','trends','trends_uint')
   AND column_name LIKE 'value%';

SELECT 'ozel nesneler' AS bolum,
  (SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema = DATABASE()) AS triggers,
  (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = DATABASE()) AS routines,
  (SELECT COUNT(*) FROM information_schema.events   WHERE event_schema   = DATABASE()) AS events,
  (SELECT COUNT(*) FROM information_schema.views    WHERE table_schema   = DATABASE()) AS views;

SELECT status AS host_status, COUNT(*) AS adet FROM hosts GROUP BY status;
SELECT COUNT(*) AS aktif_item FROM items WHERE status = 0 AND flags IN (0,4);

-- Asagidaki sorgulardan bazilari Zabbix surumune gore hata verebilir, normaldir (--force ile devam eder).
SELECT COUNT(*) AS proxy_sayisi_7x FROM proxy;
SELECT hk_history_mode, hk_history_global, hk_history, hk_trends_mode, hk_trends_global, hk_trends FROM config;
SELECT name, value_str, value_int FROM settings WHERE name LIKE 'hk_%' OR name LIKE 'compress%';
SELECT ha_nodeid, name, status FROM ha_node;
SQL

  section "Baska veritabanlari / kullanicilar (zabbix disinda DB'yi kullanan var mi?)"
  mysql "$@" --force --table <<'SQL'
SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024/1024,2) AS gb
  FROM information_schema.tables GROUP BY table_schema;
SELECT user, host FROM mysql.user;
SELECT user, host, db, command, time FROM information_schema.processlist WHERE command <> 'Sleep' OR user <> 'zabbix';
SQL
}

server_info() {
  sys_info
  local mask='password|psk|token|secret'
  section "Zabbix paketleri"
  (rpm -qa 2>/dev/null | grep -Ei 'zabbix|php|nginx|httpd|apache|grafana') \
    || (dpkg -l 2>/dev/null | grep -Ei 'zabbix|php|nginx|apache|grafana' | awk '{print $2, $3}')
  section "Zabbix server surumu / durumu"
  zabbix_server -V 2>/dev/null | head -3
  systemctl is-active zabbix-server 2>/dev/null
  section "zabbix_server.conf (sifreler haric)"
  for f in /etc/zabbix/zabbix_server.conf /etc/zabbix/zabbix_server.d/*.conf; do
    [ -f "$f" ] && { echo "-- $f"; grep -Ev '^\s*(#|$)' "$f" | grep -Eiv "$mask"; }
  done
  section "Frontend ayari (sifreler haric)"
  for f in /etc/zabbix/web/zabbix.conf.php /usr/share/zabbix/conf/zabbix.conf.php /usr/share/zabbix/ui/conf/zabbix.conf.php; do
    [ -f "$f" ] && { echo "-- $f"; grep -Ev '^\s*(//|$)' "$f" | grep -Eiv "$mask"; }
  done
  section "PHP"
  php -v 2>/dev/null | head -1
  php -m 2>/dev/null | grep -Ei 'mysqli|pgsql|pdo' | paste -sd' '
  section "Web sunucu / diger servisler"
  systemctl list-units --type=service --state=running --no-legend 2>/dev/null \
    | grep -Ei 'nginx|httpd|apache|php|grafana|zabbix' | awk '{print $1}'
  section "DB'ye dogrudan baglanan baska seyler? (cron, script)"
  grep -rIl -Ei 'mysql|mysqldump' /etc/cron* /var/spool/cron /usr/lib/zabbix /etc/zabbix 2>/dev/null | head -30
}

case "${1:-}" in
  db)     shift; db_info "$@" ;;
  server) shift; server_info ;;
  *)      sed -n '2,10p' "$0"; exit 1 ;;
esac
