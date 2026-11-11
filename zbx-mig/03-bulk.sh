#!/usr/bin/env bash
# FAZ 1 — Toplu aktarim: KLON MySQL -> PostgreSQL (history*, trends*, auditlog). Kesinti yok, canliya yuk yok.
# Yarida kesilirse ayni komutla kaldigi yerden devam eder. tmux/screen icinde calistirin.
#   ./03-bulk.sh [tablo ...]     (varsayilan: tum zaman serisi tablolari, buyukten kucuge)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
init_workdir; start_log
build_colmap clone

[[ $(pgq "SELECT count(*) FROM zbxmig.watermark WHERE name = 'clone'") == 1 ]] || die "once 02-create-schema.sh calismali"
[[ $(pgq "SELECT count(*) FROM zbxmig.watermark") == 1 ]] ||
  die "delta gecisi (05/06) zaten calismis; toplu aktarim ondan once bitmis olmali. Bastan almak icin: RESET=1 ./02-create-schema.sh"

tables=("$@"); (( $# )) || tables=("${HIST_TABLES[@]}" "$AUDIT_TABLE")
t_all=$(date +%s)
my clone -e "SELECT itemid FROM items ORDER BY itemid" > "$WORK_DIR/clone-itemids.txt"
log "klonda $(wc -l < "$WORK_DIR/clone-itemids.txt" | tr -d ' ') item; birim basina $BATCH_ITEMS item, paralel $PARALLEL_BULK"

for t in "${tables[@]}"; do
  phase="bulk.$t"; plan="$WORK_DIR/plan/$phase.tsv"; t0=$(date +%s)
  step "$t"
  if [[ $t == "$AUDIT_TABLE" ]]; then
    printf '%s.00000\t%s\tclone\tplain\t\n' "$phase" "$t" > "$plan"
  else
    # PK (itemid, clock, ns) uzerinde itemid araliklari: MySQL'de sirali okuma, birimler birbirinden bagimsiz
    awk -v k="$BATCH_ITEMS" -v t="$t" -v p="$phase" '
      BEGIN { lo = 0 }
      NR % k == 0 { printf "%s.%05d\t%s\tclone\tplain\tWHERE itemid >= %s AND itemid < %s\n", p, n++, t, lo, $1; lo = $1 }
      END { printf "%s.%05d\t%s\tclone\tplain\tWHERE itemid >= %s\n", p, n, t, lo }' "$WORK_DIR/clone-itemids.txt" > "$plan"
  fi
  register_plan "$phase" "$plan"
  run_phase "$phase" "$PARALLEL_BULK"
  rows=$(pgq "SELECT COALESCE(sum(rows_written), 0) FROM zbxmig.progress WHERE phase = '$phase'")
  el=$(( $(date +%s) - t0 )); log "    $t: $rows satir, $el sn ($(( rows / (el > 0 ? el : 1) )) satir/sn)"
  if [[ $COMPRESS_INLINE == 1 && $t != "$AUDIT_TABLE" ]]; then "$MIG_DIR/04-compress.sh" "$t"; fi
done

step "Istatistikler (ANALYZE)"
printf '%s\n' "${tables[@]}" | xargs -P "$COMPRESS_PARALLEL" -I{} psql -X -q -c 'ANALYZE "{}"'

step "OZET"
phase_summary bulk.
log "veritabani boyutu: $(pgq "SELECT pg_size_pretty(pg_database_size(current_database()))")"
log "FAZ 1 TAMAM — toplam $(( ($(date +%s) - t_all) / 60 )) dk. Siradaki: ./07-verify.sh bulk (istege bagli, uzun) ve ./05-catchup.sh"
