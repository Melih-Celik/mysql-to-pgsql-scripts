#!/usr/bin/env bash
# Tek bir is birimini calistirir: MySQL SELECT -> (pipe) -> PostgreSQL COPY.
# Kullanim: lib-worker.sh <faz> <birim-id>   (run_phase tarafindan cagrilir)
#
# COPY ile "tamamlandi" isareti AYNI transaction icindedir: mysql istemcisi hata verirse
# psql \copy basarisiz olur, transaction geri alinir, birim "pending" kalir ve yeniden denenir.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap - ERR
use_workdir

phase=$1 id=$2
line=$(awk -F'\t' -v id="$id" '$1 == id { print; exit }' "$WORK_DIR/plan/$phase.tsv")
[[ -n $line ]] || { echo "$id: plan satiri yok" >> "$WORK_DIR/log/failed-units.log"; exit 1; }
IFS=$'\t' read -r _ tbl src mode where <<<"$line"
[[ -r $WORK_DIR/my-$src.cnf ]] || { echo "$id: '$src' MySQL kaynagi tanimli degil" >> "$WORK_DIR/log/failed-units.log"; exit 1; }

cols=$(tbl_cols "$tbl")
sqlf="$WORK_DIR/units/$id.sql"
printf 'SET SESSION net_write_timeout = 7200;\nSELECT %s FROM `%s` %s;\n' "$(tbl_sel "$tbl")" "$tbl" "${where:-}" > "$sqlf"
prog="$(my_cmd "$src") < $sqlf"

written="(SELECT COALESCE(sum(n_tup_ins + n_tup_upd), 0) FROM pg_stat_xact_all_tables WHERE schemaname IN ('public', '_timescaledb_internal'))"
begin="UPDATE zbxmig.progress SET started = clock_timestamp() WHERE id = '$id'"

case $mode in
  plain|replace)
    [[ $mode == replace ]] && PGOPTIONS="$PGOPTIONS -c session_replication_role=replica"
    args=(-c "$begin"
          -c "\\copy \"$tbl\" ($cols) from program '$prog'"
          -c "UPDATE zbxmig.progress SET status = 'done', finished = clock_timestamp(), rows_written = $written, rows_read = $written WHERE id = '$id'")
    ;;
  upsert)
    args=(-c "$begin"
          -c "CREATE TEMP TABLE _s (LIKE \"$tbl\") ON COMMIT DROP"
          -c "\\copy _s ($cols) from program '$prog'"
          -c "INSERT INTO \"$tbl\" ($cols) SELECT $cols FROM _s ON CONFLICT $(conflict_clause "$tbl")"
          -c "UPDATE zbxmig.progress SET status = 'done', finished = clock_timestamp(), rows_read = (SELECT count(*) FROM _s), rows_written = $written WHERE id = '$id'")
    ;;
  *) echo "$id: bilinmeyen mod $mode" >> "$WORK_DIR/log/failed-units.log"; exit 1 ;;
esac

if out=$(psql -X -q -1 -v ON_ERROR_STOP=1 "${args[@]}" 2>&1); then
  rm -f "$sqlf"
else
  printf '%s  %s: %s\n' "$(date '+%F %T')" "$id" "$out" >> "$WORK_DIR/log/failed-units.log"
  exit 1
fi
