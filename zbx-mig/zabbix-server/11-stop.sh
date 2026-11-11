#!/usr/bin/env bash
# KESINTI BASLANGICI: Zabbix server ve frontend'i durdurur. Bundan sonra canli MySQL'e kimse yazmaz.
# (Proxy'ler ve agent'lar veriyi tamponlar; server acilinca gonderirler.)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
date +%s > "$BACKUP_DIR/downtime.start"
step "zabbix-server durduruluyor (cache'ler veritabanina yaziliyor; birkac dakika surebilir)"
systemctl disable zabbix-server >/dev/null 2>&1 || true   # olasi bir reboot'ta eski DB'ye baglanip acilmasin
timeout 900 systemctl stop zabbix-server || die "zabbix-server 15 dk'da durmadi: journalctl -u zabbix-server, tail /var/log/zabbix/zabbix_server.log"
! pgrep -x zabbix_server >/dev/null || die "zabbix_server surecleri hala calisiyor"
tail -5 "$(conf_get LogFile)" 2>/dev/null | sed 's/^/      /' >&2 || true
step "Frontend durduruluyor: $(active_web | paste -sd' ' -)"
web=$(active_web); [[ -z $web ]] || systemctl stop $web
log "DURDURULDU $(date '+%F %T'). Simdi: (1) vCenter'dan bu VM'in snapshot'ini alin  (2) DB makinesinde ./06-cutover.sh"
