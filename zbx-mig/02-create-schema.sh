#!/usr/bin/env bash
# Bos Zabbix semasi (resmi server.sql.gz) + TimescaleDB hypertable'lari + gecis takip tablolari.
# Varsayilan: veritabaninda tablo varsa durur.  RESET=1 ./02-create-schema.sh  -> veritabanini silip bastan kurar.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need ZABBIX_VERSION PG_ZABBIX_USER
init_workdir; start_log
assert_clone_idle

SQL_DIR=${SQL_SCRIPTS_DIR:-/usr/share/zabbix/sql-scripts/postgresql}
if [[ ! -s $SQL_DIR/server.sql.gz ]]; then
  step "zabbix-sql-scripts $ZABBIX_VERSION kuruluyor"
  el=$(rpm -E '%{rhel}')
  dnf -y -q install "https://repo.zabbix.com/zabbix/${ZABBIX_VERSION%.*}/stable/rhel/$el/$(uname -m)/zabbix-sql-scripts-$ZABBIX_VERSION-release1.el$el.noarch.rpm"
fi
[[ -s $SQL_DIR/server.sql.gz && -s $SQL_DIR/timescaledb/schema.sql ]] || die "$SQL_DIR altinda server.sql.gz / timescaledb/schema.sql yok"

step "Surum eslesmesi (sema dosyasi <-> MySQL dbversion)"
want=$(my clone -e "SELECT CONCAT(mandatory, ',', optional) FROM dbversion")
have=$(zcat "$SQL_DIR/server.sql.gz" | awk -F"'" 'toupper($0) ~ /^INSERT INTO DBVERSION/ && !n++ { print $4 "," $6 }')
log "    MySQL: $want   sema dosyasi: $have"
[[ $want == "$have" ]] || die "sema dosyasi ile MySQL'deki Zabbix DB surumu farkli — ZABBIX_VERSION'i ve paketi kontrol edin"

n=$(pgq "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")
if (( n > 0 )); then
  [[ ${RESET:-0} == 1 ]] || die "'$PG_DB' veritabaninda $n tablo var. Bastan kurmak icin: RESET=1 $0  (PostgreSQL'e aktarilmis TUM veri silinir)"
  step "RESET=1: veritabani silinip yeniden olusturuluyor"
  PGDATABASE=postgres pg -c "DROP DATABASE \"$PG_DB\" WITH (FORCE)" \
                         -c "CREATE DATABASE \"$PG_DB\" OWNER \"$PG_ZABBIX_USER\" ENCODING 'UTF8' TEMPLATE template0"
  pg -c "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE"
fi

step "Zabbix semasi yukleniyor (sahip: $PG_ZABBIX_USER)"
as_zabbix() { PGOPTIONS="-c role=$PG_ZABBIX_USER -c client_min_messages=warning" pg "$@"; }
zcat "$SQL_DIR/server.sql.gz" | as_zabbix >/dev/null

step "TimescaleDB hypertable'lari (resmi timescaledb/schema.sql)"
PGOPTIONS="-c role=$PG_ZABBIX_USER -c client_min_messages=error" pg -f "$SQL_DIR/timescaledb/schema.sql" >/dev/null

step "Varsayilan veriler temizleniyor (veri MySQL'den gelecek)"
pg -c "DO \$\$ BEGIN EXECUTE 'TRUNCATE ' || (SELECT string_agg(format('%I.%I', schemaname, tablename), ', ') FROM pg_tables WHERE schemaname = 'public'); END \$\$"

step "Gecis takip tablolari (zbxmig semasi)"
pg <<'SQL'
CREATE SCHEMA IF NOT EXISTS zbxmig;
CREATE TABLE IF NOT EXISTS zbxmig.progress (
  id text PRIMARY KEY, phase text NOT NULL, tbl text NOT NULL, status text NOT NULL DEFAULT 'pending',
  rows_read bigint, rows_written bigint, started timestamptz, finished timestamptz);
CREATE INDEX IF NOT EXISTS progress_phase ON zbxmig.progress (phase, status);
CREATE TABLE IF NOT EXISTS zbxmig.watermark (
  id serial PRIMARY KEY, name text NOT NULL, ts bigint NOT NULL, at timestamptz NOT NULL DEFAULT now());
SQL

step "Sema karsilastirmasi (MySQL <-> PostgreSQL)"
"$MIG_DIR/07-verify.sh" schema

step "Klon ani (ilk delta gecisinin baslangic noktasi)"
ts=${CLONE_TS:-$(my clone -e "SELECT MAX(lastaccess) FROM ha_node")}
[[ $ts =~ ^[0-9]+$ ]] || die "klon ani bulunamadi — config.env'de CLONE_TS=<epoch> verin (klonun alindigi an)"
now=$(date +%s)
(( ts <= now && ts > now - 45 * 86400 )) || die "klon ani supheli: $(fmt_ts "$ts") — config.env'de CLONE_TS ile duzeltin"
pg -c "INSERT INTO zbxmig.watermark (name, ts) VALUES ('clone', $ts)"
log "    klon ani: $(fmt_ts "$ts")  (yanlissa: CLONE_TS ile RESET=1 calistirin)"
log "SEMA HAZIR — siradaki adim: ./03-bulk.sh  (uzun surer; tmux/screen icinde calistirin)"
