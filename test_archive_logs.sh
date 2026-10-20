#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'Для тестов нужен Bash 4.4+ и GNU-утилиты (например, Kali Linux).\n' >&2
    exit 1
fi

export LC_ALL=C
unset TAR_OPTIONS GLOBIGNORE
set -o pipefail
shopt -s nullglob dotglob

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
script=$(realpath -e -- "${1:-$test_dir/archive_logs.sh}") || exit 1
[[ -f "$script" ]] || { printf 'Нет скрипта: %s\n' "$script" >&2; exit 1; }

for tool in bash realpath mktemp truncate touch tar stat find sort cmp grep; do
    command -v "$tool" >/dev/null || { printf 'Не найдена команда: %s\n' "$tool" >&2; exit 1; }
done

test_root=$(mktemp -d) || exit 1
trap 'rm -r -- "$test_root"' EXIT
export TEST_REAL_TAR
export TEST_REAL_STAT
export TEST_REAL_FIND
TEST_REAL_TAR=$(command -v tar)
TEST_REAL_STAT=$(command -v stat)
TEST_REAL_FIND=$(command -v find)

fail() {
    printf '  Ошибка теста: %s\n' "$1" >&2
    if [[ -f "${case_root:-}/output.txt" ]]; then
        printf '  Вывод проверяемого скрипта:\n' >&2
        sed -n '1,100p' "$case_root/output.txt" >&2
    fi
    return 1
}

assert() {
    if ! "$@"; then
        fail "проверка не выполнена: $*"
        return 1
    fi
}

prepare() {
    case_root="$test_root/$1"
    log_dir="$case_root/log folder"
    backup_dir="$case_root/backup folder"
    mkdir -p "$log_dir" "$backup_dir" "$case_root/expected"
}

make_file() {
    printf '%s\n' "$3" > "$1"
    truncate -s "$2" "$1"
}

run_ok() {
    if ! bash "$script" "$log_dir" "$backup_dir" "$1" "$2" > "$case_root/output.txt" 2>&1; then
        fail 'ожидался успешный запуск'
        return 1
    fi
}

run_bad() {
    if bash "$script" "$@" > "$case_root/output.txt" 2>&1; then
        fail 'ожидался ненулевой код завершения'
        return 1
    fi
}

min_log_bytes=536870912

assert_min_log_size() {
    local total=0 entry
    for entry in "$log_dir"/*; do
        [[ -f "$entry" && ! -L "$entry" ]] || continue
        total=$((total + $(stat -c %s -- "$entry")))
    done
    assert test "$total" -ge "$min_log_bytes"
}

assert_no_archive() {
    local entries=("$backup_dir"/*)
    assert test "${#entries[@]}" -eq 0
}

test_1_invalid_input() {
    prepare invalid
    make_file "$log_dir/keep.log" 536870912 'must remain untouched'
    cp "$log_dir/keep.log" "$case_root/expected/keep.log"
    assert_min_log_size
    run_bad
    run_bad "$case_root/missing" "$backup_dir" 1024 50
    run_bad "$log_dir" "$case_root/missing" 1024 50
    run_bad "$log_dir" "$backup_dir" 0 50
    run_bad "$log_dir" "$backup_dir" 1.5 50
    run_bad "$log_dir" "$backup_dir" 1024 101
    run_bad "$log_dir" "$backup_dir" 1024 '50%'
    run_bad "$log_dir" "$backup_dir" 17592186044416 50
    run_bad "$log_dir" "$log_dir" 1024 50
    assert cmp -s "$log_dir/keep.log" "$case_root/expected/keep.log"
    assert_no_archive
}

test_2_below_threshold() {
    prepare below
    make_file "$log_dir/.small file.log" 536870912 'small file content'
    cp "$log_dir/.small file.log" "$case_root/expected/small.log"
    mkdir "$log_dir/subfolder"
    make_file "$log_dir/subfolder/ignored.log" 209715200 'nested file'
    ln -s "$log_dir/subfolder/ignored.log" "$log_dir/ignored-link"
    assert_min_log_size
    run_ok 1024 60
    assert grep -Fqx 'Размер файлов log: 536870912 байт' "$case_root/output.txt"
    assert grep -Fqx 'Заполнение: 50%' "$case_root/output.txt"
    assert grep -Fqx 'Порог не превышен. Архивация не нужна.' "$case_root/output.txt"
    assert cmp -s "$log_dir/.small file.log" "$case_root/expected/small.log"
    assert test -f "$log_dir/subfolder/ignored.log"
    assert test -L "$log_dir/ignored-link"
    assert_no_archive
}

test_3_exact_threshold() {
    prepare equal
    make_file "$log_dir/exact.log" 536870912 'exact boundary'
    cp "$log_dir/exact.log" "$case_root/expected/exact.log"
    assert_min_log_size
    run_ok 1024 50
    assert grep -Fqx 'Заполнение: 50%' "$case_root/output.txt"
    assert grep -Fqx 'Порог не превышен. Архивация не нужна.' "$case_root/output.txt"
    assert cmp -s "$log_dir/exact.log" "$case_root/expected/exact.log"
    assert_no_archive
}

test_4_archive_oldest() {
    prepare archive
    make_file "$log_dir/old file.log" 134217728 'oldest file content'
    make_file "$log_dir/.middle.log" 134217728 'middle file content'
    make_file "$log_dir/-new.log" 629145600 'newest file content'
    touch -d '2020-01-01 00:00:00 UTC' "$log_dir/old file.log"
    touch -d '2020-01-02 00:00:00 UTC' "$log_dir/.middle.log"
    touch -d '2020-01-03 00:00:00 UTC' "$log_dir/-new.log"
    cp -- "$log_dir/old file.log" "$log_dir/.middle.log" "$log_dir/-new.log" "$case_root/expected/"
    assert_min_log_size

    run_ok 1024 60
    assert test ! -e "$log_dir/old file.log"
    assert test ! -e "$log_dir/.middle.log"
    assert cmp -s "$log_dir/-new.log" "$case_root/expected/-new.log"
    local archives=("$backup_dir"/*.tar.gz)
    assert test "${#archives[@]}" -eq 1
    mkdir "$case_root/restored"
    assert tar -xzf "${archives[0]}" -C "$case_root/restored"
    local restored=("$case_root/restored"/*)
    assert test "${#restored[@]}" -eq 2
    assert cmp -s "$case_root/restored/old file.log" "$case_root/expected/old file.log"
    assert cmp -s "$case_root/restored/.middle.log" "$case_root/expected/.middle.log"
    assert grep -Fqx 'Заархивировано файлов: 2' "$case_root/output.txt"
    assert grep -Fqx 'Фактический размер log после архивации: 629145600 байт' "$case_root/output.txt"
    assert grep -Fqx 'Фактическое заполнение: 58%' "$case_root/output.txt"

    assert_min_log_size
    run_ok 1024 60
    archives=("$backup_dir"/*.tar.gz)
    assert test "${#archives[@]}" -eq 1
    assert cmp -s "$log_dir/-new.log" "$case_root/expected/-new.log"
}

test_5_command_failures() {
    prepare failures
    make_file "$log_dir/keep.log" 629145600 'must survive any failed archive'
    cp "$log_dir/keep.log" "$case_root/expected/keep.log"
    assert_min_log_size
    mkdir "$case_root/bin"

    local tool phase
    for tool in stat find tar; do
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'tool="${0##*/}"' \
            'case "$tool:$TEST_FAIL_PHASE:${1:-}" in' \
            '    stat:stat:*|find:find:*|tar:create:-czf|tar:verify:-tzf) exit 2 ;;' \
            'esac' \
            'case "$tool" in' \
            '    stat) exec "$TEST_REAL_STAT" "$@" ;;' \
            '    find) exec "$TEST_REAL_FIND" "$@" ;;' \
            '    tar)  exec "$TEST_REAL_TAR" "$@" ;;' \
            'esac' > "$case_root/bin/$tool"
        chmod +x "$case_root/bin/$tool"
    done

    for phase in stat find create verify; do
        if TEST_FAIL_PHASE="$phase" PATH="$case_root/bin:$PATH" \
                bash "$script" "$log_dir" "$backup_dir" 1024 50 > "$case_root/output.txt" 2>&1; then
            fail "ошибка $phase не привела к ненулевому коду завершения"
            return 1
        fi
        assert cmp -s "$log_dir/keep.log" "$case_root/expected/keep.log"
        assert_no_archive
    done
}

passed=0
failed=0
for test_name in test_1_invalid_input test_2_below_threshold test_3_exact_threshold test_4_archive_oldest test_5_command_failures; do
    ( trap - EXIT; set -e; "$test_name" )
    result=$?
    if (( result == 0 )); then
        printf 'PASS: %s\n' "$test_name"
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n' "$test_name"
        failed=$((failed + 1))
    fi
done

printf '\nИтог: %s/5 PASS, %s FAIL\n' "$passed" "$failed"
(( failed == 0 ))
