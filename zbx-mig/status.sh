#!/usr/bin/env bash
# Anlik durum: faz ilerlemesi, hiz, tahmini bitis, veritabani boyutu. Baska bir terminalden calistirilir.
#   ./status.sh        |   watch -n 30 ./status.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
init_workdir
echo "== Fazlar"
pgq "SELECT CASE WHEN phase LIKE 'bulk.%' THEN phase ELSE phase || ' (' || count(DISTINCT tbl) || ' tablo)' END,
            count(*) FILTER (WHERE status = 'done') || '/' || count(*),
            COALESCE(sum(rows_written), 0),
            COALESCE(to_char(min(started), 'MM-DD HH24:MI'), '-'),
            CASE WHEN count(*) FILTER (WHERE status <> 'done') = 0 THEN to_char(max(finished), 'MM-DD HH24:MI') ELSE 'suruyor' END
       FROM zbxmig.progress GROUP BY phase ORDER BY min(started) NULLS LAST, phase" |
  awk -F'\t' 'BEGIN { printf "%-34s %11s %15s %12s %12s\n", "faz", "birim", "satir", "basladi", "bitti" } { printf "%-34s %11s %15d %12s %12s\n", $1, $2, $3, $4, $5 }'
echo; echo "== Toplu aktarim tahmini (veri boyutuna gore agirlikli)"
# Tablo agirliklari: klon MySQL'deki veri boyutu. Ilerleme: tamamlanan birim orani (birimler itemid araligi; kabaca esit).
w=$(my clone -e "SELECT table_name, data_length FROM information_schema.tables WHERE table_schema = DATABASE()
                  AND table_name IN ('$(IFS=,; echo "${HIST_TABLES[*]}" | sed "s/,/','/g")', '$AUDIT_TABLE')")
pgq "SELECT tbl, count(*) FILTER (WHERE status = 'done'), count(*), COALESCE(extract(epoch FROM min(started)), 0), COALESCE(extract(epoch FROM max(finished)), 0)
       FROM zbxmig.progress WHERE phase LIKE 'bulk.%' GROUP BY tbl" |
awk -F'\t' -v now="$(date +%s)" 'NR == FNR { sz[$1] = $2; tot += $2; next }
     { d[$1] = $2 / $3; if ($4 > 0 && (t0 == 0 || $4 < t0)) t0 = $4 }
     END { for (t in sz) done += sz[t] * d[t]
           if (tot == 0 || t0 == 0) { print "henuz baslamadi"; exit }
           p = done / tot; el = now - t0
           printf "ilerleme: %%%.1f  (%.1f / %.1f GB kaynak veri), gecen sure: %.1f saat", p * 100, done / 2^30, tot / 2^30, el / 3600
           if (p > 0.01 && p < 1) printf ", kalan (tahmini): %.1f saat", el * (1 - p) / p / 3600
           print "" }' <(echo "$w") -
echo; echo "== PostgreSQL"
pgq "SELECT 'veritabani boyutu: ' || pg_size_pretty(pg_database_size(current_database()))"
pgq "SELECT format('%-14s %10s  chunk: %s (%s sikistirilmis)', h.hypertable_name, pg_size_pretty(hypertable_size(format('%I', h.hypertable_name)::regclass)),
            (SELECT count(*) FROM timescaledb_information.chunks c WHERE c.hypertable_name = h.hypertable_name),
            (SELECT count(*) FROM timescaledb_information.chunks c WHERE c.hypertable_name = h.hypertable_name AND c.is_compressed))
       FROM timescaledb_information.hypertables h ORDER BY hypertable_size(format('%I', h.hypertable_name)::regclass) DESC"
echo; echo "== Delta gecisleri"
pgq "SELECT name, to_char(to_timestamp(ts), 'YYYY-MM-DD HH24:MI:SS') FROM zbxmig.watermark ORDER BY id" | column -t -s $'\t'
df -h "$(pgq 'SHOW data_directory')" | sed 's/^/   /'
[[ -s $WORK_DIR/log/failed-units.log ]] && { echo; echo "== Son hatalar ($WORK_DIR/log/failed-units.log)"; tail -3 "$WORK_DIR/log/failed-units.log" | cut -c1-400; }
exit 0
