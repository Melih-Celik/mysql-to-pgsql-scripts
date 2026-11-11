#!/usr/bin/env bash
# Dogrulama (salt-okunur).
#   ./07-verify.sh schema   MySQL <-> PostgreSQL tablo/kolon listesi ayni mi
#   ./07-verify.sh config   konfigurasyon tablolari: CANLI ile satir sayisi + kolon bazinda saglama toplami (Zabbix kapaliyken birebir)
#   ./07-verify.sh bulk     history/trends: KLON ile ornek item'lar uzerinden satir sayisi + saglama (klon anina kadar)
#   ./07-verify.sh delta    history/trends: CANLI ile ornek item'lar uzerinden (klon anindan son gecise kadar)
#   ./07-verify.sh counts   history/trends/auditlog: KLON ile tam satir sayisi (UZUN surer; istege bagli)
# Ornek buyuklugu: SAMPLE_ITEMS=300 (tablo basina)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
init_workdir
mode=${1:-}; : "${SAMPLE_ITEMS:=300}"
rc=0; V="$WORK_DIR/verify"; install -d -m 700 "$V"

# Kolon bazinda saglama ifadeleri: tamsayi -> SUM, metin/blob -> md5'in ilk 32 bitinin toplami, digerleri -> COUNT.
# Iki tarafta da tam hassasiyetli (DECIMAL/numeric) sonuc verir; cikti metin olarak karsilastirilir.
sum_exprs() {  # src(clone|prod) tablo  -> "mysql ifadeleri <TAB> pg ifadeleri"
  my "$1" -e "SELECT column_name, data_type FROM information_schema.columns
               WHERE table_schema = DATABASE() AND table_name = '$2' ORDER BY ordinal_position" |
  awk -F'\t' '
    { m = "`" $1 "`"; p = "\"" $1 "\""
      if ($2 ~ /int$/)                 { me = "COALESCE(SUM(" m "),0)"; pe = "COALESCE(sum(" p "),0)" }
      else if ($2 ~ /(char|text|blob|binary|json)$/) {
        if ($2 ~ /(char|text|json)$/) m = "REPLACE(" m ",CHAR(0 USING utf8mb4),\047\047)"   # NUL PostgreSQL metninde saklanamaz; aktarimda atilir
        me = "COALESCE(SUM(CAST(CONV(LEFT(MD5(" m "),8),16,10) AS UNSIGNED)),0)"
        pe = "COALESCE(sum((\047x\047 || left(md5(" p "),8))::bit(32)::bigint),0)" }
      else if ($2 ~ /^(double|float)$/) {
        # ayni IEEE islem dizisi iki tarafta da ayni tamsayiyi verir (deger*1000 mod 1000003)
        me = "CAST(COALESCE(SUM(CASE WHEN ABS(" m ") < 1e290 THEN FLOOR(" m "*1000 - 1000003*FLOOR(" m "*1000/1000003)) ELSE 0 END),0) AS SIGNED)"
        pe = "COALESCE(sum(CASE WHEN abs(" p ") < 1e290 THEN floor(" p "*1000 - 1000003*floor(" p "*1000/1000003)) ELSE 0 END),0)::bigint" }
      else                             { me = "COUNT(" m ")"; pe = "count(" p ")" }
      ml = ml "," me; pl = pl "," pe }
    END { print "COUNT(*)" ml "\tcount(*)" pl }'
}

case $mode in
schema)
  my clone -e "SELECT CONCAT(table_name, '.', column_name) FROM information_schema.columns WHERE table_schema = DATABASE() ORDER BY 1" | LC_ALL=C sort > "$V/schema.mysql"
  pgq "SELECT table_name || '.' || column_name FROM information_schema.columns WHERE table_schema = 'public' ORDER BY 1" | LC_ALL=C sort > "$V/schema.pg"
  if diff "$V/schema.mysql" "$V/schema.pg" > "$V/schema.diff"; then
    log "    sema ayni: $(wc -l < "$V/schema.pg" | tr -d ' ') kolon, $(cut -d. -f1 "$V/schema.pg" | sort -u | wc -l | tr -d ' ') tablo"
  else
    sed 's/^</      sadece MySQL:/; s/^>/      sadece PostgreSQL:/' "$V/schema.diff" | grep sadece | head -40 >&2
    die "MySQL ve PostgreSQL semalari farkli (ozel tablo/kolon veya surum farki) — ayrinti: $V/schema.diff"
  fi
  ;;

config)
  [[ -s $WORK_DIR/colmap.tsv ]] || build_colmap prod
  one() {  # tablo
    local t=$1 me pe a b
    IFS=$'\t' read -r me pe < <(sum_exprs prod "$t")
    a=$(my prod -e "SELECT $me FROM \`$t\`" | tr '\t' ' ')
    b=$(pgq "SELECT $pe FROM \"$t\"" | tr '\t' ' ')
    if [[ $a == "$b" ]]; then echo "OK $t ${a%% *}"; else echo "FARK $t mysql=[$a] pg=[$b]"; fi
  }
  export -f one sum_exprs my pgq; export WORK_DIR MYSQL_DB
  config_tables | xargs -P "$PARALLEL_CUTOVER" -I{} bash -c 'one {}' > "$V/config.out" || true
  nok=$(grep -c '^OK' "$V/config.out" || true); nbad=$(grep -vc '^OK' "$V/config.out" || true)
  log "    konfigurasyon: $nok tablo birebir ayni (satir sayisi + tum kolonlarin saglamasi), $nbad farkli; toplam $(awk '$1 == "OK" { s += $3 } END { print s + 0 }' "$V/config.out") satir"
  if (( nbad > 0 )); then grep -v '^OK' "$V/config.out" | cut -c1-300 | sed 's/^/      /' | head -30 >&2; rc=1; fi
  ;;

bulk|delta)
  clone_ts=$(pgq "SELECT ts FROM zbxmig.watermark WHERE name = 'clone' ORDER BY id DESC LIMIT 1")
  split=$(( clone_ts - OVERLAP ))
  if [[ $mode == bulk ]]; then src=clone; lo=0; hi=$split
  else
    src=prod; lo=$split; hi=$(last_watermark)
    (( hi > clone_ts )) || die "henuz delta gecisi yapilmamis"
  fi
  log "    kaynak: $src, pencere: $( (( lo )) && fmt_ts "$lo" || echo 'en bastan') -> $(fmt_ts "$hi"), tablo basina $SAMPLE_ITEMS ornek item"
  for t in "${HIST_TABLES[@]}"; do
    IFS=$'\t' read -r me pe < <(sum_exprs "$src" "$t")
    # ornek: verisi olan item'lar arasindan esit aralikli
    ids=$(my "$src" -e "SELECT itemid FROM items WHERE value_type IN ($(value_types_for "$t")) ORDER BY itemid" |
          awk -v n="$SAMPLE_ITEMS" '{ a[NR] = $1 } END { s = NR / n; if (s < 1) s = 1; for (i = 1; i <= NR; i += s) printf "%s%s", (c++ ? "," : ""), a[int(i)] }')
    [[ -n $ids ]] || { log "    $t: item yok"; continue; }
    w="itemid IN ($ids) AND clock >= $lo AND clock < $hi"
    my "$src" -e "SELECT itemid, $me FROM \`$t\` WHERE $w GROUP BY itemid" | LC_ALL=C sort > "$V/$mode.$t.mysql"
    pgq "SELECT itemid, $pe FROM \"$t\" WHERE $w GROUP BY itemid" | LC_ALL=C sort > "$V/$mode.$t.pg"
    n=$(wc -l < "$V/$mode.$t.mysql" | tr -d ' '); rows=$(awk -F'\t' '{ s += $2 } END { print s + 0 }' "$V/$mode.$t.mysql")
    if [[ $mode == delta ]]; then
      # item bazinda: ayni | PostgreSQL'de fazla satir (canlida housekeeper silmis: normal) | eksik satir | ayni sayi, farkli icerik
      read -r same extra miss chg < <(LC_ALL=C join -t $'\t' -a 1 -e 0 -o 1.2,2.2,1.3,2.3 \
          <(awk -F'\t' '{ k = $1; c = $2; sub(/^[^\t]*\t[^\t]*\t?/, ""); gsub(/\t/, " "); print k "\t" c "\t" $0 }' "$V/$mode.$t.mysql") \
          <(awk -F'\t' '{ k = $1; c = $2; sub(/^[^\t]*\t[^\t]*\t?/, ""); gsub(/\t/, " "); print k "\t" c "\t" $0 }' "$V/$mode.$t.pg") |
        awk -F'\t' '{ if ($2 + 0 < $1 + 0) m++; else if ($2 + 0 > $1 + 0) e++; else if ($3 != $4) c++; else s++ } END { print s + 0, e + 0, m + 0, c + 0 }')
      if (( miss == 0 && chg == 0 )); then log "    $t: OK — $n item / $rows satir; $same item birebir, $extra item'da PostgreSQL'de fazla satir (canlida housekeeper silmis)"
      else log "    $t: FARK — $miss item'da PostgreSQL'de EKSIK satir, $chg item'da icerik farkli, $same item birebir (bkz. $V/$mode.$t.*)"; rc=1; fi
    elif cmp -s "$V/$mode.$t.mysql" "$V/$mode.$t.pg"; then log "    $t: OK — $n item / $rows satir birebir (sayi + saglama)"
    else log "    $t: FARK — $(diff "$V/$mode.$t.mysql" "$V/$mode.$t.pg" | grep -c '^<' || true) item farkli (bkz. $V/$mode.$t.*)"; rc=1; fi
  done
  if [[ $mode == delta ]] && (( rc )); then log "    NOT: Zabbix calisirken bu farklar normaldir (gec gelen veri, guncellenen trend). Zabbix durdurulduktan sonraki geciste fark OLMAMALIDIR."; fi
  ;;

counts)
  clone_ts=$(pgq "SELECT ts FROM zbxmig.watermark WHERE name = 'clone' ORDER BY id DESC LIMIT 1")
  hi=$(( clone_ts - OVERLAP ))
  for t in "${HIST_TABLES[@]}" "$AUDIT_TABLE"; do
    a=$(my clone -e "SELECT COUNT(*) FROM \`$t\` WHERE clock < $hi"); b=$(pgq "SELECT count(*) FROM \"$t\" WHERE clock < $hi")
    if [[ $a == "$b" ]]; then log "    $t: OK — $a satir"; else log "    $t: FARK — mysql=$a pg=$b"; rc=1; fi
  done
  ;;

*) die "kullanim: $0 schema|config|bulk|delta|counts" ;;
esac
exit $rc
