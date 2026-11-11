#!/usr/bin/env bash
# On kontrol (SALT-OKUNUR): baglanti, surum, kapasite ve canli sistemden alinacak ayar onerileri.
# Yeni PostgreSQL makinesinde (klon) calistirilir. Hicbir seyi degistirmez.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
init_workdir
rc=0
bad() { log "  [HATA]  $*"; rc=1; }
ok()  { log "  [OK]    $*"; }
inf() { log "  [BILGI] $*"; }

step "Bu makine canli MySQL olmamali"
if ip -o addr 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$PROD_MYSQL_HOST"; then
  bad "bu makinenin IP'si PROD_MYSQL_HOST ($PROD_MYSQL_HOST) ile ayni — scriptler KLON uzerinde calismali"
else
  ok "yerel IP'ler arasinda $PROD_MYSQL_HOST yok"
fi

step "MySQL baglantilari"
for s in clone prod; do
  if v=$(my "$s" -e "SELECT CONCAT(@@version, ' / dbversion ', (SELECT CONCAT(mandatory, '-', optional) FROM dbversion))" 2>&1); then
    ok "$s: $v"; eval "ver_$s=\$v"
  else
    bad "$s: baglanamadi: $v"
  fi
done
[[ ${ver_clone:-x} == "${ver_prod:-y}" ]] || bad "klon ve canli MySQL/Zabbix surumleri farkli"

if [[ -n ${ver_prod:-} ]]; then
  step "Canli sistem: baglanti sayisi (PG_MAX_CONNECTIONS icin)"
  IFS=$'\t' read -r maxc used cur flush < <(my prod -e "
     SELECT @@max_connections,
            (SELECT variable_value FROM performance_schema.global_status WHERE variable_name = 'Max_used_connections'),
            (SELECT variable_value FROM performance_schema.global_status WHERE variable_name = 'Threads_connected'),
            @@innodb_flush_log_at_trx_commit")
  inf "max_connections=$maxc  Max_used_connections=$used  su an=$cur  innodb_flush_log_at_trx_commit=$flush"
  inf "ONERI: PG_MAX_CONNECTIONS >= $(( used + used / 5 + 30 ))   (config.env'de su an: ${PG_MAX_CONNECTIONS:-yok})"
  [[ ${PG_MAX_CONNECTIONS:-0} -ge $(( used + 30 )) ]] || bad "PG_MAX_CONNECTIONS (${PG_MAX_CONNECTIONS:-0}) canlidaki tepe baglanti sayisindan ($used) dusuk"

  step "Canli sistem: proxy gecikmesi (delta gecislerinden once tum proxy'ler guncel olmali)"
  my prod -e "SELECT p.name, UNIX_TIMESTAMP() - r.lastaccess FROM proxy p JOIN proxy_rtdata r ON r.proxyid = p.proxyid ORDER BY 2 DESC" |
  while IFS=$'\t' read -r name lag; do
    if (( lag > 300 )); then log "  [UYARI] proxy '$name' $lag sn'dir baglanmiyor — tamponundaki eski veri delta penceresinin disinda kalabilir"
    else log "  [OK]    proxy '$name' ($lag sn)"; fi
  done

  step "Canli sistem: saat farki"
  d=$(( $(my prod -e "SELECT UNIX_TIMESTAMP()") - $(date +%s) ))
  (( ${d#-} <= 5 )) && ok "canli MySQL ile saat farki ${d} sn" || bad "canli MySQL ile saat farki ${d} sn — chrony/NTP'yi duzeltin"
fi

if [[ -n ${ver_clone:-} ]]; then
  step "Klon MySQL: bellek ve boyut"
  IFS=$'\t' read -r bp gb conns < <(my clone -e "
     SELECT ROUND(@@innodb_buffer_pool_size/1024/1024/1024, 1),
            (SELECT ROUND(SUM(data_length + index_length)/1024/1024/1024) FROM information_schema.tables WHERE table_schema = DATABASE()),
            (SELECT COUNT(*) FROM information_schema.processlist WHERE id <> CONNECTION_ID())")
  ram=$(awk '/MemTotal/ { printf "%d", $2/1024/1024 }' /proc/meminfo)
  inf "veritabani ~${gb} GB, buffer pool ${bp} GB, makine RAM ${ram} GB, vCPU $(nproc)"
  awk -v bp="$bp" -v ram="$ram" 'BEGIN { exit !(bp > ram * 0.3) }' &&
    bad "klon MySQL buffer pool (${bp} GB) RAM'in %30'undan buyuk; PostgreSQL ile ayni makinede OOM riski. Klonda: mysql -uroot -p -e \"SET PERSIST innodb_buffer_pool_size = 4*1024*1024*1024\"" ||
    ok "klon MySQL buffer pool uygun"
  (( conns == 0 )) && ok "klon MySQL'e baska baglanti yok" || bad "klon MySQL'de $conns baska baglanti var — klona kimse yazmamali"

  step "Disk"
  free=$(df -BG --output=avail /var/lib 2>/dev/null | tail -1 | tr -dc 0-9)
  inf "/var/lib bos alan: ${free} GB; sikistirma oncesi PostgreSQL ihtiyaci kabaca MySQL boyutunun 1.0-1.4 kati (~$(( gb * 14 / 10 )) GB)"
  (( free > gb * 14 / 10 )) && ok "bos alan yeterli gorunuyor" ||
    warn "bos alan sinirda: COMPRESS_INLINE=1 kalsin; mumkunse diski buyutun"
fi

step "Saat senkronizasyonu"
if timedatectl 2>/dev/null | grep -q 'synchronized: yes'; then ok "NTP senkron"; else log "  [UYARI] NTP senkron degil — 01-install-postgres.sh chronyd'yi kurup baslatir; sonrasinda 'chronyc tracking' ile dogrulayin"; fi

step "Istemciler"
for b in mysql psql; do command -v $b >/dev/null && ok "$b: $($b --version)" || inf "$b yok (psql 01-install-postgres.sh ile kurulur)"; done

(( rc == 0 )) && step "ON KONTROL TAMAM" || step "ON KONTROL: yukaridaki [HATA] satirlarini duzeltin"
exit $rc
