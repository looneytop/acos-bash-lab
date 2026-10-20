#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'Ошибка: нужен Bash версии 4.4 или новее\n' >&2
    exit 1
fi

set -o pipefail
export LC_ALL=C

fail() {
    printf 'Ошибка: %s\n' "$1" >&2
    exit 1
}

if [[ $# -ne 4 ]]; then
    printf 'Использование: %s ПАПКА_LOG ПАПКА_BACKUP ЛИМИТ_В_МиБ ПОРОГ_В_ПРОЦЕНТАХ\n' "$0" >&2
    exit 1
fi

log_dir="$1"
backup_dir="$2"
limit_mib="$3"
threshold="$4"

[[ -d "$log_dir" ]] || fail "папка log не существует: $log_dir"
[[ -d "$backup_dir" ]] || fail "папка backup не существует: $backup_dir"
[[ "$limit_mib" =~ ^[1-9][0-9]*$ ]] || fail 'лимит должен быть положительным целым числом МиБ'
[[ "$threshold" =~ ^(100|[1-9]?[0-9])$ ]] || fail 'порог должен быть целым числом от 0 до 100'

# Чтобы умножение на 100 не переполнило 64-битное целое число Bash.
max_safe_bytes=92233720368547758
if (( ${#limit_mib} > 11 )) || (( limit_mib > 87960930222 )); then
    fail 'лимит слишком велик для безопасного расчёта в Bash'
fi

log_dir=$(realpath -e -- "$log_dir") || fail 'не удалось определить полный путь log'
backup_dir=$(realpath -e -- "$backup_dir") || fail 'не удалось определить полный путь backup'

if [[ "$backup_dir" == "$log_dir" ||
      "$backup_dir" == "${log_dir%/}/"* ||
      "$log_dir" == "${backup_dir%/}/"* ]]; then
    fail 'log и backup должны быть отдельными папками без вложения друг в друга'
fi

[[ -r "$log_dir" && -w "$log_dir" && -x "$log_dir" ]] || fail 'нет прав для работы с log'
[[ -w "$backup_dir" && -x "$backup_dir" ]] || fail 'нет прав для записи в backup'

size_bytes=0
shopt -s nullglob dotglob

for file in "$log_dir"/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    file_size=$(stat -c %s -- "$file") || fail "не удалось узнать размер файла: $file"
    if (( file_size > max_safe_bytes - size_bytes )); then
        fail 'суммарный размер слишком велик для безопасного расчёта в Bash'
    fi
    size_bytes=$((size_bytes + file_size))
done

limit_bytes=$((limit_mib * 1024 * 1024))
used_percent=$((size_bytes * 100 / limit_bytes))

printf 'Папка с логами: %s\n' "$log_dir"
printf 'Папка для архивов: %s\n' "$backup_dir"
printf 'Лимит: %s МиБ\n' "$limit_mib"
printf 'Порог: %s%%\n' "$threshold"
printf 'Размер файлов log: %s байт\n' "$size_bytes"
printf 'Заполнение: %s%%\n' "$used_percent"

if (( size_bytes * 100 <= limit_bytes * threshold )); then
    printf 'Порог не превышен. Архивация не нужна.\n'
    exit 0
fi

printf 'Порог превышен. Нужно выбрать старые файлы.\n'

list_file=$(mktemp) || fail 'не удалось создать временный список'
trap 'rm -f -- "$list_file"' EXIT

if ! find "$log_dir" -maxdepth 1 -type f -printf '%T@ %p\0' |
        sort -z -n > "$list_file"; then
    fail 'не удалось получить и отсортировать список файлов'
fi
mapfile -d '' -t dated_files < "$list_file" || fail 'не удалось прочитать список файлов'

remaining_bytes="$size_bytes"
files_to_archive=()

for item in "${dated_files[@]}"; do
    if (( remaining_bytes * 100 <= limit_bytes * threshold )); then
        break
    fi

    file="${item#* }"
    [[ -f "$file" && ! -L "$file" ]] || fail "файл исчез или изменил тип: $file"
    file_size=$(stat -c %s -- "$file") || fail "не удалось узнать размер файла: $file"
    if (( file_size > remaining_bytes )); then
        fail 'файлы изменились во время выполнения; запусти скрипт повторно'
    fi
    files_to_archive+=("$file")
    remaining_bytes=$((remaining_bytes - file_size))
done

if (( ${#files_to_archive[@]} == 0 || remaining_bytes * 100 > limit_bytes * threshold )); then
    fail 'не удалось выбрать достаточно файлов для достижения порога'
fi

printf 'Нужно архивировать файлов: %s\n' "${#files_to_archive[@]}"
printf 'Расчётный размер log после их удаления: %s байт\n' "$remaining_bytes"

relative_files=()
for file in "${files_to_archive[@]}"; do
    printf 'Выбран: %s\n' "$file"
    relative_files+=("${file##*/}")
done

stamp=$(date +%Y%m%d_%H%M%S) || fail 'не удалось получить дату'
archive_path=$(mktemp --tmpdir="$backup_dir" --suffix=.tar.gz "logs_${stamp}_XXXXXX") ||
    fail 'не удалось создать файл архива'

if ! tar -czf "$archive_path" -C "$log_dir" -- "${relative_files[@]}"; then
    rm -f -- "$archive_path"
    fail 'не удалось создать архив; оригиналы сохранены'
fi

if ! tar -tzf "$archive_path" >/dev/null; then
    rm -f -- "$archive_path"
    fail 'архив не прошёл проверку; оригиналы сохранены'
fi

printf 'Архив создан и проверен: %s\n' "$archive_path"

for file in "${files_to_archive[@]}"; do
    if ! rm -- "$file"; then
        fail "не удалось удалить файл: $file; его копия есть в архиве"
    fi
done

actual_size=0
for file in "$log_dir"/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    file_size=$(stat -c %s -- "$file") || fail "не удалось узнать размер файла: $file"
    if (( file_size > max_safe_bytes - actual_size )); then
        fail 'суммарный размер слишком велик для безопасного расчёта в Bash'
    fi
    actual_size=$((actual_size + file_size))
done

actual_percent=$((actual_size * 100 / limit_bytes))
printf 'Фактический размер log после архивации: %s байт\n' "$actual_size"
printf 'Фактическое заполнение: %s%%\n' "$actual_percent"
printf 'Заархивировано файлов: %s\n' "${#files_to_archive[@]}"

if (( actual_size * 100 > limit_bytes * threshold )); then
    fail 'после архивации порог всё ещё превышен: возможно, файлы менялись во время работы'
fi
