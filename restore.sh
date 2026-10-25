#!/usr/bin/env bash
# Восстанавливает последний бэкап из S3 во ВРЕМЕННУЮ базу, проверяет данные и удаляет её.
# Боевая база не затрагивается. Код возврата: 0 - всё хорошо, 1 - любая проблема.
#
#   ./restore.sh                  # последний бэкап
#   ./restore.sh <manifest-key>   # конкретный бэкап
#   KEEP_DB=1 ./restore.sh        # не удалять временную базу (для ручного осмотра)
set -Eeuo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

MIN_RATIO="${RESTORE_MIN_RATIO:-0.95}"
started=$SECONDS
tmp="$(mktemp -d)"
tmpdb="restore_check_$(date -u +%Y%m%d%H%M%S)_$$"
created=0

cleanup() {
    rm -rf "$tmp"
    if [[ $created -eq 1 && "${KEEP_DB:-0}" != 1 ]]; then
        pg dropdb -U "$POSTGRES_USER" --if-exists "$tmpdb" >/dev/null 2>&1 || log "не удалось удалить $tmpdb"
    elif [[ $created -eq 1 ]]; then
        log "временная база оставлена: $tmpdb"
    fi
}
trap cleanup EXIT
trap 'die "строка $LINENO: команда завершилась с ошибкой"' ERR

[[ "$tmpdb" != "$POSTGRES_DB" ]] || die "временная база совпала с боевой"

# 1. Выбор бэкапа: последний манифест (имя содержит UTC-время, сортировка по имени = по времени)
manifest_key="${1:-}"
if [[ -z "$manifest_key" ]]; then
    manifest_key="$(s3 s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "${S3_PREFIX}${POSTGRES_DB}_" \
        --query 'Contents[].Key' --output text | tr '\t' '\n' | grep '\.manifest$' | sort | tail -n 1 || true)"
fi
[[ -n "$manifest_key" ]] || die "в s3://${S3_BUCKET}/${S3_PREFIX} нет ни одного бэкапа"
log "бэкап: ${manifest_key}"

s3 s3 cp --only-show-errors "s3://${S3_BUCKET}/${manifest_key}" "$tmp/manifest"
manifest() { grep -m1 "^$1=" "$tmp/manifest" | cut -d= -f2-; }
dump_key="$(manifest dump_key)"
[[ -n "$dump_key" ]] || die "в манифесте нет dump_key"

# 2. Скачивание и проверка контрольной суммы
s3 s3 cp --only-show-errors "s3://${S3_BUCKET}/${dump_key}" "$tmp/dump"
[[ "$(sha256_of "$tmp/dump")" == "$(manifest sha256)" ]] || die "sha256 дампа не совпадает с манифестом"
log "sha256 совпал, размер $(wc -c < "$tmp/dump" | tr -d ' ') байт"

# 3. Восстановление во временную базу (--exit-on-error: любая ошибка = провал)
pg createdb -U "$POSTGRES_USER" "$tmpdb"
created=1
pg pg_restore -U "$POSTGRES_USER" -d "$tmpdb" --no-owner --no-privileges --exit-on-error < "$tmp/dump"
log "pg_restore выполнен во временную базу $tmpdb"

# 4. Проверка данных: каждая таблица из манифеста существует, не пуста и не сильно меньше,
#    чем была перед дампом (допуск MIN_RATIO на удаления, случившиеся между count и pg_dump)
tables=0
while IFS='=' read -r name expected; do
    [[ "$name" == table.* ]] || continue
    t="${name#table.}"
    actual="$(psql_app "$tmpdb" "SELECT count(*) FROM \"$t\"")" || die "таблица $t не читается"
    (( actual > 0 )) || die "таблица $t пуста после восстановления"
    awk -v a="$actual" -v e="$expected" -v r="$MIN_RATIO" 'BEGIN { exit !(a >= e * r) }' \
        || die "таблица $t: восстановлено $actual строк, ожидалось не менее ${MIN_RATIO} от $expected"
    log "OK  $t: $actual строк (в манифесте $expected)"
    tables=$((tables + 1))
done < "$tmp/manifest"
(( tables > 0 )) || die "в манифесте нет таблиц для проверки (задайте VERIFY_TABLES)"

# 5. Ссылочная целостность: все внешние ключи подтверждены на восстановленных данных
bad="$(psql_app "$tmpdb" "SELECT count(*) FROM pg_constraint WHERE contype = 'f' AND NOT convalidated")"
[[ "$bad" == 0 ]] || die "непроверенных внешних ключей: $bad"

log "RESTORE OK: ${tables} таблиц проверено за $((SECONDS - started)) с"
