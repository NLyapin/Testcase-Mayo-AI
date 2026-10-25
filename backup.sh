#!/usr/bin/env bash
# Дамп базы -> S3, затем удаление дампов старше RETENTION_DAYS (по умолчанию 30).
#
# В S3 для каждого бэкапа пишется два объекта:
#   <prefix><db>_<UTC-время>.dump      pg_dump -Fc
#   <prefix><db>_<UTC-время>.manifest  sha256, размер и число строк по VERIFY_TABLES
# Манифест загружается последним: он признак того, что бэкап полный. restore.sh
# ищет только по манифестам, поэтому оборвавшаяся загрузка никогда не будет выбрана.
set -Eeuo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

RETENTION_DAYS="${RETENTION_DAYS:-30}"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "RETENTION_DAYS должен быть числом"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
base="${POSTGRES_DB}_${stamp}"
dump_key="${S3_PREFIX}${base}.dump"
manifest_key="${S3_PREFIX}${base}.manifest"

s3 s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null || {
    log "бакет $S3_BUCKET не найден, создаю"
    s3 s3api create-bucket --bucket "$S3_BUCKET" >/dev/null
}

# 1. Количество строк до дампа: нижняя граница для проверки в restore.sh
{
    for t in $VERIFY_TABLES; do
        echo "table.$t=$(psql_app "$POSTGRES_DB" "SELECT count(*) FROM \"$t\"")"
    done
} > "$tmp/counts"

# 2. Дамп. Custom-формат сжат и позволяет pg_restore --list для проверки целостности
log "pg_dump ${POSTGRES_DB} -> ${dump_key}"
pg pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "$tmp/dump"
[[ -s "$tmp/dump" ]] || die "дамп пустой"
pg pg_restore --list < "$tmp/dump" >/dev/null || die "pg_restore не читает свежий дамп"

size="$(wc -c < "$tmp/dump" | tr -d ' ')"
{
    echo "dump_key=${dump_key}"
    echo "created_at=${stamp}"
    echo "size=${size}"
    echo "sha256=$(sha256_of "$tmp/dump")"
    cat "$tmp/counts"
} > "$tmp/manifest"

# 3. Загрузка и проверка, что в S3 лёг объект нужного размера
s3 s3 cp --only-show-errors "$tmp/dump" "s3://${S3_BUCKET}/${dump_key}"
remote_size="$(s3 s3api head-object --bucket "$S3_BUCKET" --key "$dump_key" --query ContentLength --output text)"
[[ "$remote_size" == "$size" ]] || die "размер в S3 ($remote_size) != локальному ($size)"
s3 s3 cp --only-show-errors "$tmp/manifest" "s3://${S3_BUCKET}/${manifest_key}"
log "загружено: ${size} байт, manifest ${manifest_key}"

# 4. Ротация. Выполняется только после успешной загрузки (set -e), поэтому при сбое
#    S3/дампа старые бэкапы не удаляются. Объекты текущего запуска не трогаем.
cutoff="$(date -u -d "${RETENTION_DAYS} days ago" +%FT%T 2>/dev/null || date -u -v-"${RETENTION_DAYS}"d +%FT%T)"
deleted=0
while IFS=$'\t' read -r modified key; do
    [[ -n "$key" && "$key" != "$dump_key" && "$key" != "$manifest_key" ]] || continue
    # LastModified вида 2026-10-25T08:38:04+00:00: сравниваем первые 19 символов как строки
    if [[ "${modified:0:19}" < "$cutoff" ]]; then
        s3 s3 rm --only-show-errors "s3://${S3_BUCKET}/${key}"
        log "удалён старше ${RETENTION_DAYS} дн.: ${key}"
        deleted=$((deleted + 1))
    fi
done < <(s3 s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$S3_PREFIX" \
            --query 'Contents[].[LastModified,Key]' --output text | grep -v '^None$' || true)

log "готово, удалено старых объектов: ${deleted}"
