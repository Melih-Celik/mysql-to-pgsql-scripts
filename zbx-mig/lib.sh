#!/usr/bin/env bash
# zbx-mig ortak kutuphane — dogrudan calistirilmaz, diger scriptler "source" eder.

set -Eeuo pipefail

MIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZBXMIG_CONF="${ZBXMIG_CONF:-$MIG_DIR/config.env}"

log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*" >&2; }
step() { log "==> $*"; }
warn() { log "UYARI: $*"; }
die()  { log "HATA: $*"; exit 1; }
trap 'log "HATA: satir $LINENO: komut basarisiz: $BASH_COMMAND"' ERR

[[ -f $ZBXMIG_CONF ]] || die "ayar dosyasi yok: $ZBXMIG_CONF (config.env.example -> config.env)"
# shellcheck disable=SC1090
source "$ZBXMIG_CONF"

: "${MYSQL_DB:=zabbix}" "${CLONE_MYSQL_PORT:=3306}" "${PROD_MYSQL_PORT:=3306}"
: "${PG_VERSION:=17}" "${PG_HOST:=127.0.0.1}" "${PG_PORT:=5432}" "${PG_DB:=zabbix}"
: "${PG_ZABBIX_USER:=zabbix}" "${PG_MIG_USER:=zbxmig}" "${WORK_DIR:=/var/lib/zbxmig}"
: "${PARALLEL_BULK:=4}" "${PARALLEL_ONLINE:=2}" "${PARALLEL_CUTOVER:=6}" "${BATCH_ITEMS:=500}"
: "${OVERLAP:=10800}" "${CLONE_TS:=}" "${COMPRESS_INLINE:=1}" "${COMPRESS_PARALLEL:=2}"
: "${HK_HISTORY:=}" "${HK_TRENDS:=}"
: "${PROD_MYSQL_HOST:=}" "${PROD_MYSQL_USER:=}" "${PROD_MYSQL_PASSWORD:=}" "${ZABBIX_SERVER_IP:=}"
(( OVERLAP >= 3600 && OVERLAP <= 5 * 86400 )) || die "OVERLAP 3600 ile 432000 sn arasinda olmali (sikistirilmis chunk'lara delta yazilmasin)"

# Zaman serisi tablolari: toplu (klon) + delta (canli) ile tasinir. Sira = yukleme sirasi (buyukten kucuge).
HIST_TABLES=(history_uint trends_uint history trends history_text history_str history_log history_bin)
AUDIT_TABLE=auditlog

need() {
  local v
  for v in "$@"; do
    [[ -n ${!v:-} && ${!v} != DEGISTIR ]] || die "config.env icinde $v doldurulmamis"
  done
}

# items.value_type -> history tablosu eslesmesi (delta sorgularinda sadece ilgili item'lar taranir)
value_types_for() {
  case $1 in
    history|trends)           echo 0 ;;
    history_str)              echo 1 ;;
    history_log)              echo 2 ;;
    history_uint|trends_uint) echo 3 ;;
    history_text)             echo 4 ;;
    history_bin)              echo 5 ;;
    *) die "bilinmeyen history tablosu: $1" ;;
  esac
}

conflict_clause() {
  case $1 in
    trends|trends_uint)
      echo '(itemid,clock) DO UPDATE SET num=EXCLUDED.num, value_min=EXCLUDED.value_min, value_avg=EXCLUDED.value_avg, value_max=EXCLUDED.value_max' ;;
    *) echo 'DO NOTHING' ;;
  esac
}

# --- Guvenlik: canli sisteme dokunmama garantileri -------------------------------------------------
# 1) PROD_MYSQL_* bos ise (TEST MODU) my-prod.cnf hic yazilmaz; canliya baglanan adimlar calismayi reddeder.
# 2) Klon MySQL ve PostgreSQL adresleri bu makinenin kendi adresi olmak zorundadir.
# 3) Scriptlerin actigi her MySQL oturumu sunucu tarafinda salt-okunurdur (init-command).
# 4) "Klon" MySQL'e canli bir Zabbix yaziyorsa (assert_clone_idle) scriptler durur.
have_prod() { [[ -n $PROD_MYSQL_HOST && $PROD_MYSQL_HOST != DEGISTIR ]]; }
need_prod() {
  have_prod || die "bu adim CANLI MySQL'e baglanir; config.env'de PROD_MYSQL_HOST bos (TEST MODU) oldugu icin calistirilmadi"
  need PROD_MYSQL_USER PROD_MYSQL_PASSWORD
}
local_ips() { ip -o addr 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }
is_local_host() {
  case $1 in localhost|127.*|::1) return 0 ;; esac
  local_ips | grep -qxF -- "$1"
}

# Klon MySQL'e calisan bir Zabbix server yaziyor mu? Calisan server ha_node.lastaccess'i 5 sn'de bir gunceller
# (veritabani saatiyle). Yaziyorsa burasi klon degil CANLI veritabanidir -> hicbir sey yapmadan dur.
assert_clone_idle() {
  local q="SELECT COALESCE(MAX(lastaccess), 0), UNIX_TIMESTAMP() FROM ha_node" a b now
  IFS=$'\t' read -r a now < <(my clone -e "$q") || die "klon MySQL'e baglanilamadi ($CLONE_MYSQL_HOST:$CLONE_MYSQL_PORT)"
  [[ $a =~ ^[0-9]+$ && $now =~ ^[0-9]+$ ]] || die "klon MySQL'de ha_node okunamadi"
  (( now - a > 120 )) ||
    die "GUVENLIK: bu MySQL'e $(( now - a )) sn once bir Zabbix server yazmis — burasi klon degil CANLI veritabani gorunuyor. Hicbir islem yapilmadi."
  sleep 6
  IFS=$'\t' read -r b now < <(my clone -e "$q") || die "klon MySQL'e baglanilamadi"
  [[ $a == "$b" ]] || die "GUVENLIK: ha_node.lastaccess degisiyor — bu MySQL'e calisan bir Zabbix server bagli (CANLI veritabani). Hicbir islem yapilmadi."
  log "    guvenlik: bu makinedeki MySQL'e Zabbix yazmiyor (son yazma $(( (now - a) / 3600 )) saat once) — klon"
}

_write_mycnf() {  # ad host port user sifre
  local f="$WORK_DIR/my-$1.cnf" pw=${5//\\/\\\\}
  pw=${pw//\"/\\\"}
  # init-command: oturum salt-okunur acilir; INSERT/UPDATE/DELETE/DDL sunucu tarafinda reddedilir (ERROR 1792)
  ( umask 077; printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\ndefault-character-set=utf8mb4\nconnect-timeout=10\ninit-command="SET SESSION transaction_read_only=ON"\n' \
      "$2" "$3" "$4" "$pw" > "$f" )
}

# Calisma dizini + istemci kimlik dosyalari. Her scriptin basinda bir kez cagrilir.
init_workdir() {
  need CLONE_MYSQL_HOST CLONE_MYSQL_USER CLONE_MYSQL_PASSWORD PG_MIG_PASSWORD
  [[ $WORK_DIR != *[[:space:]\']* ]] || die "WORK_DIR bosluk/tirnak iceremez: $WORK_DIR"
  is_local_host "$CLONE_MYSQL_HOST" ||
    die "GUVENLIK: CLONE_MYSQL_HOST ($CLONE_MYSQL_HOST) bu makinenin adresi degil — klon MySQL, scriptlerin calistigi makinede olmali (127.0.0.1)"
  is_local_host "$PG_HOST" ||
    die "GUVENLIK: PG_HOST ($PG_HOST) bu makinenin adresi degil — PostgreSQL, scriptlerin calistigi makinede olmali (127.0.0.1)"
  install -d -m 700 "$WORK_DIR" "$WORK_DIR/units" "$WORK_DIR/plan" "$WORK_DIR/log"
  _write_mycnf clone "$CLONE_MYSQL_HOST" "$CLONE_MYSQL_PORT" "$CLONE_MYSQL_USER" "$CLONE_MYSQL_PASSWORD"
  if have_prod; then
    need PROD_MYSQL_USER PROD_MYSQL_PASSWORD
    ! is_local_host "$PROD_MYSQL_HOST" ||
      die "GUVENLIK: bu makine CANLI MySQL ($PROD_MYSQL_HOST) — scriptler sadece klonda calisir"
    _write_mycnf prod "$PROD_MYSQL_HOST" "$PROD_MYSQL_PORT" "$PROD_MYSQL_USER" "$PROD_MYSQL_PASSWORD"
  else
    rm -f "$WORK_DIR/my-prod.cnf"
  fi
  local pw=${PG_MIG_PASSWORD//\\/\\\\}
  ( umask 077; printf '%s:%s:*:%s:%s\n' "$PG_HOST" "$PG_PORT" "$PG_MIG_USER" "${pw//:/\\:}" > "$WORK_DIR/pgpass" )
  use_workdir
}

# Sadece ortam degiskenleri (worker'lar icin; dosya yazmaz).
use_workdir() {
  export PGHOST=$PG_HOST PGPORT=$PG_PORT PGUSER=$PG_MIG_USER PGDATABASE=$PG_DB
  export PGPASSFILE="$WORK_DIR/pgpass" PGCONNECT_TIMEOUT=10
  export PGOPTIONS="-c synchronous_commit=off -c client_min_messages=warning"
}

# Ciktiyi ayni anda log dosyasina da yaz.
start_log() {
  local f
  f="$WORK_DIR/log/$(basename "$0" .sh)-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$f") 2>&1
  log "log: $f"
  if have_prod; then log "kaynaklar: klon MySQL $CLONE_MYSQL_HOST (bu makine) | canli MySQL $PROD_MYSQL_HOST (sadece SELECT)"
  else log "TEST MODU: canli MySQL tanimli degil — sadece bu makinedeki MySQL ($CLONE_MYSQL_HOST) ve PostgreSQL ($PG_HOST) kullanilir"; fi
}

# my <clone|prod> [mysql argumanlari]  — sekmeyle ayrilmis, basliksiz, ham cikti
# Kimlik dosyasi yoksa (TEST MODU'nda my-prod.cnf) baglanti denenmez.
my() {
  [[ -r $WORK_DIR/my-$1.cnf ]] || { echo "HATA: '$1' MySQL kaynagi tanimli degil (TEST MODU'nda canliya baglanilmaz)" >&2; return 1; }
  mysql --defaults-extra-file="$WORK_DIR/my-$1.cnf" --batch --skip-column-names --raw "${@:2}" "$MYSQL_DB"
}
my_cmd() { echo "mysql --defaults-extra-file=$WORK_DIR/my-$1.cnf --batch --skip-column-names --raw --quick $MYSQL_DB"; }
pg()     { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
# psu: yerel "postgres" isletim sistemi kullanicisi ile (peer auth) — rol/veritabani olusturma ve temizlik icin
psu()    { runuser -u postgres -- env -u PGHOST -u PGUSER -u PGDATABASE -u PGPASSFILE -u PGOPTIONS \
             "/usr/pgsql-$PG_VERSION/bin/psql" -X -q -v ON_ERROR_STOP=1 -p "$PG_PORT" "$@"; }
pgq()    { psql -X -qAt -F $'\t' -v ON_ERROR_STOP=1 -c "$1"; }

# Kaynak semadan kolon haritasi: tablo <TAB> "pg kolon listesi" <TAB> mysql select listesi.
# Metin kolonlari PostgreSQL COPY metin bicimine MySQL tarafinda kacislanir (\\, \t, \n, \r; NUL atilir),
# NULL -> \N, blob -> \\x<hex> (bytea). Sayisal kolonlar oldugu gibi gider.
build_colmap() {  # $1 = clone|prod
  my "$1" -e "SELECT table_name, column_name, data_type, is_nullable
                FROM information_schema.columns
               WHERE table_schema = DATABASE()
               ORDER BY table_name, ordinal_position" |
  awk '
    BEGIN { FS = "\t"; OFS = "\t"; bs = "CHAR(92 USING utf8mb4)" }
    function flush() { if (t != "") print t, cols, sel }
    {
      if ($1 != t) { flush(); t = $1; cols = ""; sel = "" }
      q = "`" $2 "`"
      if ($3 ~ /^(char|varchar|tinytext|text|mediumtext|longtext|json|enum|set)$/)
        e = "REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(" q "," bs ",REPEAT(" bs ",2)),CHAR(9 USING utf8mb4),CONCAT(" bs ",\047t\047)),CHAR(10 USING utf8mb4),CONCAT(" bs ",\047n\047)),CHAR(13 USING utf8mb4),CONCAT(" bs ",\047r\047)),CHAR(0 USING utf8mb4),\047\047)"
      else if ($3 ~ /(blob|binary)$/)
        e = "CONCAT(REPEAT(" bs ",2),\047x\047,HEX(" q "))"
      else
        e = q
      if ($4 == "YES") e = "IFNULL(" e ",CONCAT(" bs ",\047N\047))"
      cols = cols (cols == "" ? "" : ",") "\"" $2 "\""
      sel  = sel  (sel  == "" ? "" : ",") e
    }
    END { flush() }
  ' > "$WORK_DIR/colmap.tsv"
  [[ -s $WORK_DIR/colmap.tsv ]] || die "kolon haritasi bos — MySQL baglantisini/veritabani adini kontrol edin"
}
tbl_cols() { awk -F'\t' -v t="$1" '$1 == t { print $2; exit }' "$WORK_DIR/colmap.tsv"; }
tbl_sel()  { awk -F'\t' -v t="$1" '$1 == t { print $3; exit }' "$WORK_DIR/colmap.tsv"; }

# history/trends/auditlog disindaki tum tablolar (kesinti aninda canlidan tam kopyalanir)
config_tables() {
  local skip
  skip=$(printf '%s\n' "${HIST_TABLES[@]}" "$AUDIT_TABLE")
  cut -f1 "$WORK_DIR/colmap.tsv" | grep -vxF "$skip"
}

# Plan dosyasi: id <TAB> tablo <TAB> kaynak <TAB> mod <TAB> where
# Mod: plain = dogrudan COPY | upsert = gecici tablo + ON CONFLICT (tekrarlanabilir) | replace = FK/trigger kapali COPY
register_plan() {  # faz planfile
  cut -f1,2 "$2" | pg -c "CREATE TEMP TABLE _p (id text, tbl text)" \
                      -c "\\copy _p from pstdin" \
                      -c "INSERT INTO zbxmig.progress (id, phase, tbl) SELECT id, '$1', tbl FROM _p ON CONFLICT (id) DO NOTHING"
}

_ticker() {  # faz
  local d t r
  while sleep 60; do
    IFS=$'\t' read -r d t r < <(pgq "SELECT count(*) FILTER (WHERE status='done'), count(*), COALESCE(sum(rows_written),0)
                                      FROM zbxmig.progress WHERE phase='$1'") || continue
    log "    $1: $d/$t birim, $r satir"
  done
}

# Bir fazin bekleyen tum birimlerini paralel calistirir; basarisizlari 3 kez dener.
run_phase() {  # faz paralel
  local phase=$1 par=$2 try pending n tick
  _ticker "$phase" & tick=$!
  for try in 1 2 3; do
    pending=$(pgq "SELECT id FROM zbxmig.progress WHERE phase='$phase' AND status<>'done' ORDER BY id")
    [[ -z $pending ]] && break
    log "    $phase: $(wc -l <<<"$pending" | tr -d ' ') birim (deneme $try, paralel $par)"
    xargs -P "$par" -n 1 "$MIG_DIR/lib-worker.sh" "$phase" <<<"$pending" || true
  done
  kill "$tick" 2>/dev/null || true; wait "$tick" 2>/dev/null || true
  n=$(pgq "SELECT count(*) FROM zbxmig.progress WHERE phase='$phase' AND status<>'done'")
  [[ $n == 0 ]] || die "$phase: $n birim basarisiz — ayrinti: $WORK_DIR/log/failed-units.log"
}

phase_summary() {  # faz-oneki  — en cok satir tasiyan 12 tablo + digerleri
  pgq "SELECT tbl, count(*), COALESCE(sum(rows_read),0), COALESCE(sum(rows_written),0),
              COALESCE(round(extract(epoch FROM max(finished)-min(started))),0)
         FROM zbxmig.progress WHERE phase LIKE '$1%' GROUP BY tbl ORDER BY 3 DESC, 1" |
  awk -F'\t' 'BEGIN { printf "    %-28s %7s %14s %14s %8s\n", "tablo", "birim", "okunan", "yazilan", "sure(sn)" }
              NR <= 12 { printf "    %-28s %7d %14d %14d %8d\n", $1, $2, $3, $4, $5 }
              NR > 12 { on++; ou += $2; orr += $3; ow += $4 }
              { r += $3; w += $4 }
              END { if (on) printf "    %-28s %7d %14d %14d\n", "(diger " on " tablo)", ou, orr, ow
                    printf "    %-28s %7s %14d %14d\n", "TOPLAM", "", r, w }' >&2
}

last_watermark() { pgq "SELECT ts FROM zbxmig.watermark ORDER BY id DESC LIMIT 1"; }

# Delta plani: canli MySQL'den clock >= since olan history/trends/auditlog satirlari.
plan_delta() {  # faz since
  local phase=$1 since=$2 t plan="$WORK_DIR/plan/$1.tsv"
  : > "$plan"
  for t in "${HIST_TABLES[@]}"; do
    my prod -e "SELECT itemid FROM items WHERE value_type IN ($(value_types_for "$t")) ORDER BY itemid" |
    awk -v k="$BATCH_ITEMS" -v t="$t" -v p="$phase" -v s="$since" '
      function emit() { printf "%s.%s.%05d\t%s\tprod\tupsert\tWHERE itemid IN (%s) AND clock >= %s\n", p, t, n++, t, list, s; list = "" }
      { list = list (list == "" ? "" : ",") $1; if (NR % k == 0) emit() }
      END { if (list != "") emit() }' >> "$plan"
  done
  printf '%s.%s.00000\t%s\tprod\tupsert\tWHERE clock >= %s\n' "$phase" "$AUDIT_TABLE" "$AUDIT_TABLE" "$since" >> "$plan"
  register_plan "$phase" "$plan"
}

fmt_ts() { date -d "@$1" '+%F %T' 2>/dev/null || date -r "$1" '+%F %T'; }
