#!/usr/bin/env bash
# FAZ 2 — Yakalama (catch-up): CANLI MySQL -> PostgreSQL, son gecisten bu yana gelen history/trends/auditlog.
# Zabbix calisirken (kesintisiz) calistirilir; istenildigi kadar tekrarlanabilir (ON CONFLICT ile idempotent).
# Canli MySQL'e sadece SELECT atar; yuk PARALLEL_ONLINE ile sinirlidir.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_prod
init_workdir; start_log
build_colmap prod

done_tbls=$(pgq "SELECT count(DISTINCT tbl) FROM zbxmig.progress WHERE phase LIKE 'bulk.%'")
pend=$(pgq "SELECT count(*) FROM zbxmig.progress WHERE phase LIKE 'bulk.%' AND status <> 'done'")
(( done_tbls == ${#HIST_TABLES[@]} + 1 && pend == 0 )) || die "toplu aktarim (03-bulk.sh) tamamlanmamis ($done_tbls tablo, $pend bekleyen birim)"

prev=$(last_watermark); since=$(( prev - OVERLAP ))
start_ts=$(my prod -e "SELECT UNIX_TIMESTAMP()")
phase="delta$(date +%Y%m%d%H%M%S)"; t0=$(date +%s)
step "Pencere: $(fmt_ts "$since") -> simdi  (son gecis $(fmt_ts "$prev"), geri tarama $OVERLAP sn)"

my prod -e "SELECT p.name, UNIX_TIMESTAMP() - r.lastaccess FROM proxy p JOIN proxy_rtdata r ON r.proxyid = p.proxyid WHERE UNIX_TIMESTAMP() - r.lastaccess > 300" |
while IFS=$'\t' read -r name lag; do warn "proxy '$name' $lag sn'dir baglanmiyor — tamponundaki veri sonraki gecislere kalabilir"; done

plan_delta "$phase" "$since"
run_phase "$phase" "$PARALLEL_ONLINE"
pg -c "INSERT INTO zbxmig.watermark (name, ts) VALUES ('$phase', $start_ts)"

el=$(( $(date +%s) - t0 )); (( el > 0 )) || el=1
rows=$(pgq "SELECT COALESCE(sum(rows_read), 0) FROM zbxmig.progress WHERE phase = '$phase'")
phase_summary "$phase"
span=$(( start_ts - since ))
log "CATCH-UP TAMAM: $rows satir, $el sn, pencere $(( span / 60 )) dk"
log "Kesinti anindaki son gecis icin tahmin (paralel $PARALLEL_CUTOVER, simdi baslasa): ~$(( (OVERLAP + el) * el * PARALLEL_ONLINE / span / PARALLEL_CUTOVER + 30 )) sn"
log "Kesintiden hemen once bir kez daha calistirin; ne kadar yakin calisirsa son gecis o kadar kisa surer."
