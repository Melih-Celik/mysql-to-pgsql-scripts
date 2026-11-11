#!/usr/bin/env bash
# PostgreSQL + TimescaleDB kurulumu, ayarlar, roller ve bos "zabbix" veritabani.
# Yeni DB makinesinde (MySQL klonu, EL9/EL10) root olarak calistirilir. Tekrar calistirilabilir.
#   ./01-install-postgres.sh          tam kurulum
#   ./01-install-postgres.sh tune     sadece ayarlari yeniden yaz (VM'e RAM/CPU eklendikten sonra) + restart
#   ./01-install-postgres.sh hba      sadece pg_hba.conf (config.env'e ZABBIX_SERVER_IP yazildiktan sonra) + reload
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $EUID == 0 ]] || die "root olarak calistirin"
need PG_ZABBIX_PASSWORD PG_MIG_PASSWORD TSDB_VERSION
init_workdir; start_log   # init_workdir: bu makine PROD_MYSQL_HOST ise durur

EL=$(rpm -E '%{rhel}'); ARCH=$(uname -m)
PGBIN=/usr/pgsql-$PG_VERSION/bin
PGDATA=${PGDATA_DIR:-/var/lib/pgsql/$PG_VERSION/data}
SVC=postgresql-$PG_VERSION

write_tuning() {
  local ram_mb cpus sb ecs mwm par
  ram_mb=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo); cpus=$(nproc)
  sb=$(( ram_mb / 4 )); ecs=$(( ram_mb * 65 / 100 ))
  mwm=$(( ram_mb / 16 )); (( mwm > 2048 )) && mwm=2048
  par=$(( cpus / 2 )); (( par < 2 )) && par=2
  grep -q "^include_dir = 'conf.d'" "$PGDATA/postgresql.conf" || echo "include_dir = 'conf.d'" >> "$PGDATA/postgresql.conf"
  install -d -o postgres -g postgres -m 700 "$PGDATA/conf.d"
  cat > "$PGDATA/conf.d/10-zabbix.conf" <<CONF
# zbx-mig tarafindan uretildi ($(date '+%F %T')) — RAM ${ram_mb} MB, ${cpus} vCPU
listen_addresses = '*'
port = $PG_PORT
max_connections = ${PG_MAX_CONNECTIONS:-1000}
password_encryption = scram-sha-256
shared_preload_libraries = 'timescaledb'
timescaledb.telemetry_level = off
timescaledb.max_background_workers = 16
max_worker_processes = $(( 24 + cpus ))
max_parallel_workers = $cpus
max_parallel_workers_per_gather = $par
max_parallel_maintenance_workers = $par
max_locks_per_transaction = 256

shared_buffers = ${sb}MB
effective_cache_size = ${ecs}MB
work_mem = 8MB
maintenance_work_mem = ${mwm}MB

synchronous_commit = ${PG_SYNCHRONOUS_COMMIT:-off}
wal_compression = lz4
wal_buffers = 64MB
min_wal_size = 2GB
max_wal_size = 16GB
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9

random_page_cost = $([[ ${PG_STORAGE_SSD:-1} == 1 ]] && echo 1.1 || echo 3.0)
effective_io_concurrency = $([[ ${PG_STORAGE_SSD:-1} == 1 ]] && echo 200 || echo 2)

autovacuum_max_workers = 4
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02
autovacuum_vacuum_cost_limit = 2000

log_min_duration_statement = 5000
log_checkpoints = on
log_lock_waits = on
log_autovacuum_min_duration = 10s
log_line_prefix = '%m [%p] %u@%d '
CONF
  chown postgres:postgres "$PGDATA/conf.d/10-zabbix.conf"
  log "    shared_buffers=${sb}MB effective_cache_size=${ecs}MB max_connections=${PG_MAX_CONNECTIONS:-1000}"
}

write_hba() {
  local hba="$PGDATA/pg_hba.conf"
  add_hba() { grep -qxF "$1" "$hba" || echo "$1" >> "$hba"; }
  add_hba "# zbx-mig"
  add_hba "host    all    $PG_MIG_USER    127.0.0.1/32    scram-sha-256"
  if [[ -n $ZABBIX_SERVER_IP && $ZABBIX_SERVER_IP != DEGISTIR ]]; then
    add_hba "host    $PG_DB    $PG_ZABBIX_USER    $ZABBIX_SERVER_IP/32    scram-sha-256"
    log "    pg_hba: Zabbix server $ZABBIX_SERVER_IP icin erisim satiri var"
  else
    log "    pg_hba: ZABBIX_SERVER_IP bos — disaridan erisim acilmadi (gecisten once doldurup: $0 hba)"
  fi
}

case ${1:-} in
  tune) step "Ayarlar yeniden yaziliyor"; write_tuning; systemctl restart "$SVC"; log "tamam"; exit 0 ;;
  hba)  step "pg_hba.conf"; write_hba; psu -d postgres -c "SELECT pg_reload_conf()" >/dev/null; log "tamam"; exit 0 ;;
  "")   ;;
  *)    die "kullanim: $0 [tune|hba]" ;;
esac

step "Guvenlik kontrolu"
assert_clone_idle

step "Saat senkronizasyonu (chrony)"
dnf -y -q install chrony >/dev/null 2>&1 || true
systemctl enable --now chronyd >/dev/null 2>&1 || warn "chronyd baslatilamadi — NTP'yi elle kontrol edin"

step "Depolar: PGDG (PostgreSQL $PG_VERSION) + Timescale"
rpm -q pgdg-redhat-repo >/dev/null 2>&1 ||
  dnf -y -q install "https://download.postgresql.org/pub/repos/yum/reporpms/EL-$EL-$ARCH/pgdg-redhat-repo-latest.noarch.rpm"
dnf -qy module disable postgresql >/dev/null 2>&1 || true
cat > /etc/yum.repos.d/timescale_timescaledb.repo <<REPO
[timescale_timescaledb]
name=timescale_timescaledb
baseurl=https://packagecloud.io/timescale/timescaledb/el/$EL/\$basearch
repo_gpgcheck=1
gpgcheck=0
enabled=1
gpgkey=https://packagecloud.io/timescale/timescaledb/gpgkey
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
metadata_expire=300
REPO

step "Paketler: postgresql$PG_VERSION + timescaledb $TSDB_VERSION (surum sabit)"
dnf -y -q install "postgresql$PG_VERSION-server" "postgresql$PG_VERSION-contrib" \
  "timescaledb-2-postgresql-$PG_VERSION-$TSDB_VERSION" "timescaledb-2-loader-postgresql-$PG_VERSION-$TSDB_VERSION"
# "dnf update" ile Zabbix'in desteklemedigi bir TimescaleDB surumune cikilmasin
if dnf -y -q install 'dnf-command(versionlock)' >/dev/null 2>&1; then
  dnf -q versionlock add "timescaledb-2-postgresql-$PG_VERSION" "timescaledb-2-loader-postgresql-$PG_VERSION" >/dev/null 2>&1 || true
  log "    versionlock eklendi"
else
  warn "versionlock eklentisi kurulamadi — timescaledb paketlerini guncelleme disinda tutun (dnf.conf: excludepkgs=timescaledb*)"
fi
for b in psql pg_dump vacuumdb; do ln -sf "$PGBIN/$b" /usr/local/bin/$b; done

step "initdb ($PGDATA)"
if [[ ! -s $PGDATA/PG_VERSION ]]; then
  if [[ -n ${PGDATA_DIR:-} ]]; then
    install -d -o postgres -g postgres -m 700 "$PGDATA"
    install -d /etc/systemd/system/$SVC.service.d
    printf '[Service]\nEnvironment=PGDATA=%s\n' "$PGDATA" > /etc/systemd/system/$SVC.service.d/pgdata.conf
    systemctl daemon-reload
  fi
  # C.UTF-8: MySQL'deki utf8mb4_bin ile ayni (byte sirali) karsilastirma/siralama davranisi
  PGSETUP_INITDB_OPTIONS="--encoding=UTF8 --locale=C.UTF-8 --data-checksums" "$PGBIN/postgresql-$PG_VERSION-setup" initdb
else
  log "    veri dizini zaten var, initdb atlandi"
fi

step "postgresql.conf + pg_hba.conf"
write_tuning
write_hba

step "Servis"
systemctl enable "$SVC" >/dev/null
systemctl restart "$SVC"
for _ in $(seq 30); do "$PGBIN/pg_isready" -q -p "$PG_PORT" && break; sleep 1; done
"$PGBIN/pg_isready" -p "$PG_PORT" || die "PostgreSQL baslamadi: journalctl -u $SVC"

step "Roller ve veritabani"
sq() { printf '%s' "${1//\'/\'\'}"; }
psu -d postgres <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$PG_ZABBIX_USER') THEN CREATE ROLE "$PG_ZABBIX_USER" LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$PG_MIG_USER') THEN CREATE ROLE "$PG_MIG_USER" LOGIN SUPERUSER; END IF;
END \$\$;
ALTER ROLE "$PG_ZABBIX_USER" PASSWORD '$(sq "$PG_ZABBIX_PASSWORD")';
ALTER ROLE "$PG_MIG_USER" PASSWORD '$(sq "$PG_MIG_PASSWORD")';
SQL
if [[ $(psu -d postgres -At -c "SELECT 1 FROM pg_database WHERE datname = '$PG_DB'") != 1 ]]; then
  psu -d postgres -c "CREATE DATABASE \"$PG_DB\" OWNER \"$PG_ZABBIX_USER\" ENCODING 'UTF8' TEMPLATE template0"
fi
psu -d "$PG_DB" -c "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE"

step "Dogrulama"
pgq "SELECT 'PostgreSQL ' || current_setting('server_version') || ', TimescaleDB ' || extversion || ', lisans ' || current_setting('timescaledb.license')
       FROM pg_extension WHERE extname = 'timescaledb'" >&2
[[ $(pgq "SELECT current_setting('timescaledb.license')") == timescale ]] ||
  die "TimescaleDB lisansi 'timescale' (Community) degil — sikistirma calismaz. Paket Timescale deposundan kurulmali."
log "KURULUM TAMAM — siradaki adim: ./02-create-schema.sh"
