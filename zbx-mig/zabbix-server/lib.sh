#!/usr/bin/env bash
# Zabbix server tarafi ortak kutuphane — dogrudan calistirilmaz.
set -Eeuo pipefail
SRV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*" >&2; }
step() { log "==> $*"; }
warn() { log "UYARI: $*"; }
die()  { log "HATA: $*"; exit 1; }
trap 'log "HATA: satir $LINENO: komut basarisiz: $BASH_COMMAND"' ERR
[[ $EUID == 0 ]] || die "root olarak calistirin"
[[ -f $SRV_DIR/config.env ]] || die "ayar dosyasi yok: $SRV_DIR/config.env (config.env.example -> config.env)"
# shellcheck disable=SC1091
source "$SRV_DIR/config.env"
: "${NEW_DB_PORT:=5432}" "${NEW_DB_NAME:=zabbix}" "${NEW_DB_USER:=zabbix}" "${BACKUP_DIR:=/root/zbx-mig-backup}"
: "${SERVER_CONF:=/etc/zabbix/zabbix_server.conf}" "${WEB_CONF:=/etc/zabbix/web/zabbix.conf.php}"
for v in NEW_DB_HOST NEW_DB_PASSWORD ZABBIX_VERSION; do
  [[ -n ${!v:-} && ${!v} != DEGISTIR ]] || die "config.env icinde $v doldurulmamis"
done
install -d -m 700 "$BACKUP_DIR"
exec > >(tee -a "$BACKUP_DIR/$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log") 2>&1

RPMDIR="$BACKUP_DIR/rpms"
WEB_SERVICES=(nginx httpd php-fpm)
active_web() { local s; for s in "${WEB_SERVICES[@]}"; do systemctl is-enabled -q "$s" 2>/dev/null && echo "$s"; done; return 0; }
conf_get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$SERVER_CONF"; }
# conf_set ANAHTAR DEGER dosya — varsa (yorumlu olmayan) satiri degistirir, yoksa sona ekler
conf_set() {
  local k=$1 v=$2 f=$3 tmp
  tmp=$(mktemp)
  # deger ortam degiskeniyle gecer: awk -v ters bolu (\) iceren sifreleri bozar
  K="$k" V="$v" awk 'BEGIN { FS = "="; k = ENVIRON["K"]; v = ENVIRON["V"] } $1 == k { if (!done) print k "=" v; done = 1; next } { print } END { if (!done) print k "=" v }' "$f" > "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
}
php_set() {  # $DB['KEY'] = 'value';
  local k=$1 v=${2//\\/\\\\}; v=${v//\'/\\\'}
  grep -q "^\$DB\['$k'\]" "$WEB_CONF" || die "$WEB_CONF icinde \$DB['$k'] satiri yok"
  K="$k" V="$v" perl -i -pe 's/^\$DB\[\x27\Q$ENV{K}\E\x27\]\s*=.*$/\$DB[\x27$ENV{K}\x27] = \x27$ENV{V}\x27;/' "$WEB_CONF"
}
pg_check() {  # sorgu -> sonuc (psql varsa), yoksa bash /dev/tcp ile sadece port kontrolu
  PGPASSWORD="$NEW_DB_PASSWORD" PGCONNECT_TIMEOUT=5 psql -X -At -h "$NEW_DB_HOST" -p "$NEW_DB_PORT" -U "$NEW_DB_USER" -d "$NEW_DB_NAME" -c "$1"
}
# Paket degisimi: once tamamen yerel (indirilmis rpm'ler, repo'suz), olmazsa repo'lar acik. Bagimliliklar silinmez (geri donus hizli olsun).
swap_pkg() {  # eski yeni-rpm-veya-ad
  dnf -y -q --disablerepo='*' --setopt=clean_requirements_on_remove=False swap "$1" "$2" >/dev/null 2>&1 ||
    dnf -y -q --setopt=clean_requirements_on_remove=False swap "$1" "$2" >/dev/null
}
installed_version() { if rpm -q "$1" >/dev/null 2>&1; then rpm -q --qf '%{VERSION}' "$1"; fi; }
