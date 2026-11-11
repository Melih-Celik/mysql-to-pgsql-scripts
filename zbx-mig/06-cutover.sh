#!/usr/bin/env bash
# FAZ 3 — GECIS (cutover). Zabbix server + frontend DURDURULDUKTAN sonra calistirilir.
#   1) son delta: history/trends/auditlog (son gecisten bu yana)
#   2) history/trends/auditlog disindaki TUM tablolar canlidan bastan kopyalanir (TRUNCATE + COPY)
#   3) sequence'ler, TimescaleDB ayarlari, ANALYZE, dogrulama
# Canli MySQL'e sadece SELECT atilir. Basarisiz olursa ayni komutla yeniden calistirilabilir.
#
#   ./06-cutover.sh               gercek gecis (canli MySQL'de baska baglanti varsa durur)
#   ./06-cutover.sh --rehearsal   PROVA: Zabbix calisirken ayni adimlar; sure olcmek icin. Sonuc gecerli sayilmaz.
#   ./06-cutover.sh --force       baglanti kontrolunu atla (ornegin izleme araci baglantisi kapatilamiyorsa)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
rehearsal=0; force=0
for a in "$@"; do case $a in --rehearsal) rehearsal=1 ;; --force) force=1 ;; *) die "bilinmeyen arguman: $a" ;; esac; done
need_prod
init_workdir; start_log
T0=$(date +%s); lap() { log "    [T+$(( $(date +%s) - T0 )) sn] $*"; }

pend=$(pgq "SELECT count(*) FROM zbxmig.progress WHERE phase LIKE 'bulk.%' AND status <> 'done'")
ntbl=$(pgq "SELECT count(DISTINCT tbl) FROM zbxmig.progress WHERE phase LIKE 'bulk.%'")
(( ntbl == ${#HIST_TABLES[@]} + 1 && pend == 0 )) || die "toplu aktarim (03-bulk.sh) tamamlanmamis"

step "Kontrol: canli MySQL'de Zabbix baglantisi kalmamis olmali"
others=$(my prod -e "SELECT CONCAT_WS(' ', user, host, db, command, time) FROM information_schema.processlist
                      WHERE id <> CONNECTION_ID() AND user NOT IN ('event_scheduler', 'system user')")
# ha_node: calisan server status=3 (aktif) ve lastaccess'i 5 sn'de bir gunceller; duzgun durdurulunca status=1 olur
ha=$(my prod -e "SELECT COALESCE(MIN(UNIX_TIMESTAMP() - lastaccess), 999999) FROM ha_node WHERE status IN (0, 3)")
if (( rehearsal )); then
  log "    PROVA modu: Zabbix calisiyor ($(grep -c . <<<"$others") baglanti) — kontrol atlandi"
elif [[ -n $others ]] || (( ha < 30 )); then
  [[ -n $others ]] && printf '      %s\n' "$others" >&2
  (( ha < 30 )) && log "    zabbix_server aktif gorunuyor: $ha sn once veritabanina yazmis (ha_node)"
  (( force )) || die "canli MySQL hala kullaniliyor. Zabbix server ve frontend'i durdurun (zabbix-server/11-stop.sh). Emin iseniz: --force"
  warn "--force: baglanti kontrolu atlandi"
else
  log "    baglanti yok, zabbix_server durmus"
fi

build_colmap prod
"$MIG_DIR/07-verify.sh" schema
phase="$( (( rehearsal )) && echo reh || echo cut )$(date +%Y%m%d%H%M%S)"
plan="$WORK_DIR/plan/$phase.tsv"
prev=$(last_watermark); since=$(( prev - OVERLAP ))
start_ts=$(my prod -e "SELECT UNIX_TIMESTAMP()")
lap "son delta penceresi: $(fmt_ts "$since") -> simdi"

step "Plan"
plan_delta "$phase" "$since"
# konfigurasyon tablolari: buyukten kucuge (uzun sureni ilk baslat)
cfg=$(config_tables)
my prod -e "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY data_length DESC, table_name" |
  grep -xF "$cfg" | awk -v p="$phase" '{ printf "%s.0cfg.%03d.%s\t%s\tprod\treplace\t\n", p, NR, $1, $1 }' >> "$plan"
register_plan "$phase" "$plan"
ncfg=$(wc -l <<<"$cfg" | tr -d ' ')
log "    $ncfg konfigurasyon tablosu + $(( $(wc -l < "$plan") - ncfg )) delta birimi, paralel $PARALLEL_CUTOVER"

step "Konfigurasyon tablolari bosaltiliyor"
pg -c "TRUNCATE $(sed 's/.*/"&"/' <<<"$cfg" | paste -sd, -)"

step "Aktarim"
run_phase "$phase" "$PARALLEL_CUTOVER"
pg -c "INSERT INTO zbxmig.watermark (name, ts) VALUES ('$phase', $start_ts)"
lap "aktarim bitti"

step "Dogrulama (canli MySQL ile karsilastirma)"
vrc=0
"$MIG_DIR/07-verify.sh" config || vrc=1
"$MIG_DIR/07-verify.sh" delta  || vrc=1
lap "dogrulama bitti"

step "Sequence'ler"
pgq "SELECT format('SELECT setval(%L, (SELECT COALESCE(max(%I), 0) + 1 FROM %I), false)', pg_get_serial_sequence(c.relname, a.attname), a.attname, c.relname)
       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_attribute a ON a.attrelid = c.oid
      WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
        AND pg_get_serial_sequence(c.relname, a.attname) IS NOT NULL" | pg >/dev/null

step "TimescaleDB ayarlari (settings tablosu MySQL'den geldigi icin yeniden uygulanir)"
pg <<SQL
UPDATE settings SET value_str = 'timescaledb' WHERE name = 'db_extension';
UPDATE settings SET value_int = 1 WHERE name IN ('hk_history_global', 'hk_trends_global', 'compression_status');
UPDATE settings SET value_str = '7d' WHERE name = 'compress_older';
${HK_HISTORY:+UPDATE settings SET value_str = '$HK_HISTORY' WHERE name = 'hk_history';}
${HK_TRENDS:+UPDATE settings SET value_str = '$HK_TRENDS' WHERE name = 'hk_trends';}
DO \$\$ BEGIN
  IF (SELECT count(*) FROM settings WHERE (name = 'db_extension' AND value_str = 'timescaledb')
        OR (name IN ('hk_history_global', 'hk_trends_global', 'compression_status') AND value_int = 1)) <> 4 THEN
    RAISE EXCEPTION 'settings tablosunda beklenen TimescaleDB satirlari yok';
  END IF;
END \$\$;
SQL
pgq "SELECT '    ' || name || ' = ' || CASE WHEN value_str <> '' THEN value_str ELSE value_int::text END FROM settings
      WHERE name IN ('db_extension', 'hk_history_global', 'hk_history', 'hk_trends_global', 'hk_trends', 'compression_status', 'compress_older') ORDER BY name" >&2

step "Istatistikler (ANALYZE)"
{ echo "$cfg"; printf '%s\n' "${HIST_TABLES[@]}" "$AUDIT_TABLE"; } | xargs -P "$PARALLEL_CUTOVER" -I{} psql -X -q -c 'ANALYZE "{}"'
lap "analyze bitti"

step "OZET"
phase_summary "$phase"
log "toplam sure: $(( $(date +%s) - T0 )) sn"
if (( rehearsal )); then
  log "PROVA TAMAM. Zabbix calisirken alindigi icin konfigurasyon dogrulamasindaki farklar normaldir."
  log "Gercek geciste sure bundan biraz kisa olur (son delta penceresi daha dar)."
elif (( vrc )); then
  die "DOGRULAMA BASARISIZ — Zabbix'i PostgreSQL'e BAGLAMAYIN. Farklari inceleyin; gerekirse 06-cutover.sh yeniden calistirilabilir, olmazsa geri donus: zabbix-server/13-rollback.sh"
else
  log "GECIS TAMAM — simdi Zabbix server uzerinde: ./12-switch.sh"
fi
