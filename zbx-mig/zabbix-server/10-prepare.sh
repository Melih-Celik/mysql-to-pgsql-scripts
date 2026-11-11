#!/usr/bin/env bash
# HAZIRLIK (kesintisiz, gecisten gunler once): Zabbix server uzerinde calistirilir. Calisan sisteme dokunmaz.
# - surum kontrolu, PostgreSQL baglanti testi
# - zabbix-server-pgsql / zabbix-web-pgsql paketlerini AYNI surumle onceden indirir (gecis aninda internete bagimlilik kalmaz)
# - yapilandirma yedegi
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "Kurulu Zabbix surumu"
cur=$(installed_version zabbix-server-mysql)
[[ -n $cur ]] || die "zabbix-server-mysql kurulu degil (gecis zaten yapilmis olabilir)"
[[ $cur == "$ZABBIX_VERSION" ]] || die "kurulu surum $cur, config.env'de $ZABBIX_VERSION — gecisten once Zabbix GUNCELLENMEMELI; ikisini esitleyin"
rel=$(rpm -q --qf '%{VERSION}-%{RELEASE}' zabbix-server-mysql)
log "    zabbix-server-mysql $rel"
rpm -qa 'zabbix-*' | sort | sed 's/^/      /' >&2

step "Yapilandirma yedegi -> $BACKUP_DIR/etc-zabbix.tgz"
tar -C / -czf "$BACKUP_DIR/etc-zabbix.tgz" etc/zabbix $(cd / && ls -d etc/nginx etc/httpd etc/php-fpm.d etc/php.ini 2>/dev/null)
cp -a "$SERVER_CONF" "$BACKUP_DIR/zabbix_server.conf.mysql"
cp -a "$WEB_CONF" "$BACKUP_DIR/zabbix.conf.php.mysql"
rpm -qa | sort > "$BACKUP_DIR/rpm-qa.before"
systemctl is-enabled zabbix-server "${WEB_SERVICES[@]}" 2>/dev/null | paste -sd' ' - > "$BACKUP_DIR/enabled.before" || true

step "Paketler indiriliyor (kurulmaz) -> $RPMDIR"
install -d "$RPMDIR"
pkgs=("zabbix-server-pgsql-$rel")
rpm -q zabbix-web-mysql >/dev/null 2>&1 && pkgs+=("zabbix-web-pgsql-$rel")
# geri donus icin mevcut mysql paketlerinin de kopyasi (repo'dan kalkarsa diye)
pkgs+=("zabbix-server-mysql-$rel"); rpm -q zabbix-web-mysql >/dev/null 2>&1 && pkgs+=("zabbix-web-mysql-$rel")
dnf -y -q download --resolve --destdir "$RPMDIR" "${pkgs[@]}" 2>/dev/null ||
  dnf -y -q install --downloadonly --downloaddir "$RPMDIR" "${pkgs[@]:0:2}"
# PHP PostgreSQL surucusu + psql istemcisi (kucuk, calisan sisteme etkisi yok; simdiden kurulur)
dnf -y -q install php-pgsql postgresql >/dev/null 2>&1 || warn "php-pgsql/postgresql (istemci) kurulamadi — elle kurun: dnf install php-pgsql postgresql"
ls "$RPMDIR" | sed 's/^/      /' >&2
ls "$RPMDIR"/zabbix-server-pgsql-"$ZABBIX_VERSION"-*.rpm >/dev/null 2>&1 || die "zabbix-server-pgsql-$ZABBIX_VERSION indirilemedi — Zabbix reposunu kontrol edin"

step "Gecis islemi kuru calistirma (dnf, --assumeno)"
dnf --assumeno --disablerepo='*' --setopt=clean_requirements_on_remove=False swap zabbix-server-mysql "$RPMDIR"/zabbix-server-pgsql-"$ZABBIX_VERSION"-*.rpm 2>&1 | grep -E '^(Installing|Removing|Upgrading|Downgrading|Error| +[a-z])' | head -30 >&2 || true

step "PostgreSQL baglantisi ($NEW_DB_USER@$NEW_DB_HOST:$NEW_DB_PORT/$NEW_DB_NAME)"
if command -v psql >/dev/null; then
  pg_check "SELECT 'baglanti OK — PostgreSQL ' || current_setting('server_version') || ', TimescaleDB ' || (SELECT extversion FROM pg_extension WHERE extname = 'timescaledb')" >&2 ||
    die "PostgreSQL'e baglanilamadi — pg_hba.conf (ZABBIX_SERVER_IP), firewall (5432/tcp) ve sifreyi kontrol edin"
else
  timeout 5 bash -c "exec 3<>/dev/tcp/$NEW_DB_HOST/$NEW_DB_PORT" || die "$NEW_DB_HOST:$NEW_DB_PORT portuna erisilemiyor"
  warn "psql yok; sadece port erisimi dogrulandi"
fi

step "Mevcut ayarlar"
log "    DBHost=$(conf_get DBHost) DBName=$(conf_get DBName) DBUser=$(conf_get DBUser) DBPort=$(conf_get DBPort)"
log "    web servisleri: $(active_web | paste -sd' ' -)"
[[ $(getenforce 2>/dev/null) == Enforcing ]] && warn "SELinux Enforcing: setsebool -P httpd_can_network_connect_db 1 ve zabbix_can_network 1 gerekebilir"
log "HAZIRLIK TAMAM. Gecis gunu: ./11-stop.sh -> (DB makinesinde 06-cutover.sh) -> ./12-switch.sh   | geri donus: ./13-rollback.sh"
