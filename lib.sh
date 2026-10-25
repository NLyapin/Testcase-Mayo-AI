# Общие настройки и функции для backup.sh / restore.sh. Не запускается напрямую.
cd "$(dirname "${BASH_SOURCE[0]}")"

# Значения из .env подхватываются, но переменные, заданные в окружении, имеют приоритет
# (RETENTION_DAYS=0 ./backup.sh).
if [[ -f .env ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        _k="${BASH_REMATCH[1]}"
        _v="${BASH_REMATCH[2]}"
        [[ -n "${!_k+x}" ]] || export "$_k=$(eval "printf '%s' $_v")"
    done < .env
fi

: "${POSTGRES_USER:?}" "${POSTGRES_DB:?}" "${S3_ACCESS_KEY:?}" "${S3_SECRET_KEY:?}" "${S3_BUCKET:?}"
S3_PREFIX="${S3_PREFIX:-postgres/}"
VERIFY_TABLES="${VERIFY_TABLES:-}"

export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# S3_ENDPOINT пустой -> настоящий AWS S3
s3() {
    if [[ -n "${S3_ENDPOINT:-}" ]]; then
        aws --endpoint-url "$S3_ENDPOINT" "$@"
    else
        aws "$@"
    fi
}

# psql/pg_dump/pg_restore выполняются внутри контейнера postgres (клиент той же версии 16)
pg()  { docker compose exec -T postgres "$@"; }
# </dev/null: иначе exec съедает stdin вызывающего цикла while read
psql_app() { pg psql -U "$POSTGRES_USER" -d "$1" -X -qAt -v ON_ERROR_STOP=1 -c "$2" </dev/null; }

sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

for cmd in aws docker; do command -v "$cmd" >/dev/null || die "нужен $cmd"; done
