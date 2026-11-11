#!/usr/bin/env bash
# Eski chunk'lari sikistirir (TimescaleDB columnstore). Ayarlar Zabbix server'in kendi uyguladigi ile birebir aynidir
# (segmentby=itemid, orderby=clock[,ns]); server acildiginda bunlari hazir bulur, sadece policy'yi ekler.
# Sadece klon anindan 7 gunden eski chunk'lar sikistirilir; delta gecisleri bu chunk'lara dokunmaz.
#   ./04-compress.sh [tablo ...]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
init_workdir
tables=("$@"); (( $# )) || tables=("${HIST_TABLES[@]}")
clone_ts=$(pgq "SELECT ts FROM zbxmig.watermark WHERE name = 'clone' ORDER BY id DESC LIMIT 1")
cutoff=$(( clone_ts - 7 * 86400 ))

for t in "${tables[@]}"; do
  [[ $t == trends* ]] && orderby=clock || orderby='clock,ns'
  before=$(pgq "SELECT pg_size_pretty(hypertable_size('$t'))")
  PGOPTIONS="$PGOPTIONS -c role=$PG_ZABBIX_USER" pg <<SQL
CREATE OR REPLACE FUNCTION zbx_ts_unix_now() RETURNS integer LANGUAGE sql STABLE AS \$\$ SELECT extract(epoch FROM now())::integer \$\$;
SELECT set_integer_now_func('$t', 'zbx_ts_unix_now', true) \gset _
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM timescaledb_information.hypertable_compression_settings WHERE hypertable::text = '$t' AND segmentby = 'itemid') THEN
    ALTER TABLE "$t" SET (timescaledb.enable_columnstore = true, timescaledb.segmentby = 'itemid', timescaledb.orderby = '$orderby');
  END IF;
END \$\$;
SQL
  chunks=$(pgq "SELECT format('%I.%I', chunk_schema, chunk_name) FROM timescaledb_information.chunks
                 WHERE hypertable_schema = 'public' AND hypertable_name = '$t' AND NOT is_compressed AND range_end_integer <= $cutoff
                 ORDER BY range_start_integer")
  if [[ -z $chunks ]]; then log "    $t: sikistirilacak chunk yok"; continue; fi
  n=$(wc -l <<<"$chunks" | tr -d ' '); t0=$(date +%s)
  log "    $t: $n chunk sikistiriliyor (paralel $COMPRESS_PARALLEL)"
  PGOPTIONS="$PGOPTIONS -c client_min_messages=error" \
  xargs -P "$COMPRESS_PARALLEL" -I{} psql -X -q -v ON_ERROR_STOP=1 -c "SELECT compress_chunk('{}')" <<<"$chunks" >/dev/null ||
    die "$t: sikistirma basarisiz (yeniden calistirilabilir)"
  log "    $t: $before -> $(pgq "SELECT pg_size_pretty(hypertable_size('$t'))") ($(( $(date +%s) - t0 )) sn)"
done
