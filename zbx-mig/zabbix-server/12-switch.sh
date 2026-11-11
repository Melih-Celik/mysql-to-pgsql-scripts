#!/usr/bin/env bash
# Zabbix server'i PostgreSQL'e gecirir: paket degisimi (mysql -> pgsql, ayni surum), ayar dosyalari, servisler.
# 06-cutover.sh "GECIS TAMAM" dedikten sonra calistirilir.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
! pgrep -x zabbix_server >/dev/null || die "zabbix_server calisiyor — once ./11-stop.sh"
[[ -s $BACKUP_DIR/zabbix_server.conf.mysql ]] || die "yedek yok — once ./10-prepare.sh"

step "PostgreSQL tarafi hazir mi"
if command -v psql >/dev/null; then
  ext=$(pg_check "SELECT value_str FROM settings WHERE name = 'db_extension'") || die "PostgreSQL'e baglanilamadi"
  [[ $ext == timescaledb ]] || die "PostgreSQL'de gecis tamamlanmamis (settings.db_extension='$ext') — DB makinesinde 06-cutover.sh bitmeli"
  log "    $(pg_check "SELECT 'hosts=' || (SELECT count(*) FROM hosts) || ' items=' || (SELECT count(*) FROM items) || ' dbversion=' || (SELECT mandatory FROM dbversion)")"
fi

step "Paketler: zabbix-server-mysql -> zabbix-server-pgsql ($ZABBIX_VERSION)"
if [[ -z $(installed_version zabbix-server-pgsql) ]]; then
  swap_pkg zabbix-server-mysql "$(ls "$RPMDIR"/zabbix-server-pgsql-"$ZABBIX_VERSION"-*.rpm)"
fi
if rpm -q zabbix-web-mysql >/dev/null 2>&1; then
  swap_pkg zabbix-web-mysql "$(ls "$RPMDIR"/zabbix-web-pgsql-"$ZABBIX_VERSION"-*.rpm)"
fi
[[ $(installed_version zabbix-server-pgsql) == "$ZABBIX_VERSION" ]] || die "zabbix-server-pgsql $ZABBIX_VERSION kurulamadi"
rpm -qa 'zabbix-server-*' 'zabbix-web-*' | sort | sed 's/^/      /' >&2

step "zabbix_server.conf"
# paket degisimi dosyayi .rpmsave yapmis olabilir: her durumda yedekteki (mevcut tuning'li) dosyadan baslanir
cp -a "$BACKUP_DIR/zabbix_server.conf.mysql" "$SERVER_CONF"
conf_set DBHost "$NEW_DB_HOST" "$SERVER_CONF"
conf_set DBPort "$NEW_DB_PORT" "$SERVER_CONF"
conf_set DBName "$NEW_DB_NAME" "$SERVER_CONF"
conf_set DBUser "$NEW_DB_USER" "$SERVER_CONF"
conf_set DBPassword "$NEW_DB_PASSWORD" "$SERVER_CONF"
sed -i -E 's/^(DBSocket=.*)$/# \1/' "$SERVER_CONF"
chown root:zabbix "$SERVER_CONF"; chmod 640 "$SERVER_CONF"
grep -E '^DB(Host|Port|Name|User)=' "$SERVER_CONF" | sed 's/^/      /' >&2

step "Frontend ($WEB_CONF)"
cp -a "$BACKUP_DIR/zabbix.conf.php.mysql" "$WEB_CONF"
php_set TYPE POSTGRESQL; php_set SERVER "$NEW_DB_HOST"; php_set PORT "$NEW_DB_PORT"
php_set DATABASE "$NEW_DB_NAME"; php_set USER "$NEW_DB_USER"; php_set PASSWORD "$NEW_DB_PASSWORD"
grep -q "^\$DB\['SCHEMA'\]" "$WEB_CONF" && php_set SCHEMA ''
{ php-fpm -m 2>/dev/null || php -m 2>/dev/null; } | grep -qx pgsql || die "PHP pgsql eklentisi yok: dnf install php-pgsql"
grep -E "^\\\$DB\['(TYPE|SERVER|PORT|DATABASE|USER)'\]" "$WEB_CONF" | sed 's/^/      /' >&2

step "Servisler"
logf=$(conf_get LogFile)
# sadece bu acilista yazilan log satirlarina bakilir (onceki MySQL calismasinin satirlari degil)
skip=1; [[ ! -f $logf ]] || skip=$(( $(wc -l < "$logf") + 1 ))
systemctl daemon-reload
systemctl enable --now zabbix-server >/dev/null
web=$(active_web); [[ -z $web ]] || systemctl restart $web

step "Acilis kontrolu (en fazla 3 dk)"
ok=0
for _ in $(seq 36); do
  sleep 5
  systemctl is-active -q zabbix-server || die "zabbix-server durdu — tail -50 $logf"
  new=$(tail -n "+$skip" "$logf" 2>/dev/null || true)
  if grep -q 'server #0 started \[main process\]' <<<"$new" && grep -Eq 'started \[(history syncer|configuration syncer) #1\]' <<<"$new"; then ok=1; break; fi
done
grep -Ei 'TimescaleDB|database is down|cannot|\[Z3005\]|unsupported|compression' <<<"${new:-}" | tail -15 | sed 's/^/      /' >&2 || true
(( ok )) || die "zabbix-server 3 dk icinde acilmadi — tail -100 $logf   | geri donus: ./13-rollback.sh"
if [[ -s $BACKUP_DIR/downtime.start ]]; then log "    kesinti suresi: $(( ($(date +%s) - $(cat "$BACKUP_DIR/downtime.start")) / 60 )) dk"; fi
cat >&2 <<TXT

ZABBIX POSTGRESQL ILE CALISIYOR. Kontrol listesi:
  1. Frontend'e girin: Reports > System information  (Server running: Yes; Database: PostgreSQL + TimescaleDB uyarisiz)
  2. Monitoring > Latest data: yeni veri geliyor mu; bir grafikte gecmis veri (kesinti oncesi) gorunuyor mu
  3. Administration > Proxies: tum proxy'ler baglandi mi (tamponlanan veri 5-30 dk icinde bosalir)
  4. Administration > Queue: kuyruk eriyor mu
  5. Test bildirimi (Alerts > Media types > Test)
  6. tail -f $logf   (surekli tekrar eden hata olmamali)
Sorun varsa ve cozulemiyorsa: ./13-rollback.sh  (eski MySQL'e 5 dk'da geri donus)
TXT
