#!/usr/bin/env bash
# GERI DONUS: Zabbix server'i tekrar eski MySQL'e baglar (paketler + ayar dosyalari yedekten).
# Canli MySQL gecis boyunca hic degistirilmedigi icin durdugu yerden devam eder.
# DIKKAT: PostgreSQL ile calisilan surede toplanan veri MySQL'e tasinmaz (o aralik grafiklerde bos kalir).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ -s $BACKUP_DIR/zabbix_server.conf.mysql ]] || die "yedek yok ($BACKUP_DIR)"
[[ ${1:-} == --yes ]] || die "eski MySQL'e geri donulecek; onay icin: $0 --yes"

step "Servisler durduruluyor"
systemctl stop zabbix-server 2>/dev/null || true
web=$(active_web); [[ -z $web ]] || systemctl stop $web

step "Paketler: pgsql -> mysql ($ZABBIX_VERSION)"
if [[ -n $(installed_version zabbix-server-pgsql) ]]; then
  swap_pkg zabbix-server-pgsql "$(ls "$RPMDIR"/zabbix-server-mysql-"$ZABBIX_VERSION"-*.rpm)"
fi
if rpm -q zabbix-web-pgsql >/dev/null 2>&1; then
  swap_pkg zabbix-web-pgsql "$(ls "$RPMDIR"/zabbix-web-mysql-"$ZABBIX_VERSION"-*.rpm)"
fi
[[ $(installed_version zabbix-server-mysql) == "$ZABBIX_VERSION" ]] || die "zabbix-server-mysql $ZABBIX_VERSION kurulamadi — son care: vCenter snapshot'ina donun"

step "Ayar dosyalari yedekten"
cp -a "$BACKUP_DIR/zabbix_server.conf.mysql" "$SERVER_CONF"
cp -a "$BACKUP_DIR/zabbix.conf.php.mysql" "$WEB_CONF"

step "Servisler"
systemctl daemon-reload
systemctl enable --now zabbix-server >/dev/null
[[ -z $web ]] || systemctl start $web
sleep 15
systemctl is-active -q zabbix-server || die "zabbix-server acilmadi — tail -50 $(conf_get LogFile); son care: vCenter snapshot'ina donun"
log "GERI DONUS TAMAM: Zabbix eski MySQL ($(conf_get DBHost)) ile calisiyor."
