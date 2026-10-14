#!/usr/bin/env bash
# Проверка, что собранное приложение поднимает все три бэкенда.
#
# Запускает cloudmus с отдельным HOME, offscreen-платформой Qt и в своём
# dbus-сеансе, ждёт появления бэкендов, показывает их и манифесты. Гасит только
# свои процессы: PID ищутся внутри собственного дерева процессов (лаунчер ->
# приложение -> бэкенды) и убиваются по точному значению, не по шаблону.
#
# Использование: ./smoke-test.sh [путь к cloudmus]
set -uo pipefail

bin=${1:-./result/bin/cloudmus}
[ -x "$bin" ] || { echo "нет $bin — сначала nix build" >&2; exit 1; }
bin=$(readlink -f "$bin")
command -v dbus-run-session >/dev/null || { echo "нужен dbus-run-session" >&2; exit 1; }

tmp=$(mktemp -d)
launcher_pid=""
app_pid=""
child_pids=""

cleanup() {
    set +e
    # бэкенды могли перезапуститься, поэтому список детей читаем заново
    [ -n "$app_pid" ] && child_pids=$(pgrep -P "$app_pid" 2>/dev/null | tr '\n' ' ')
    for pid in $child_pids $app_pid $launcher_pid; do
        [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    done
    sleep 0.3
    rm -rf "$tmp"
}
trap cleanup EXIT

# dbus-run-session держит свой dbus-daemon и запускает приложение отдельным
# процессом, поэтому приложение ищем по имени внутри его дерева, а не как
# «первого ребёнка».
find_app() {
    for pid in $(pgrep -f -- "$bin" 2>/dev/null); do
        [ "$pid" = "$launcher_pid" ] && continue
        [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$launcher_pid" ] && echo "$pid" && return 0
    done
    return 1
}

HOME="$tmp" \
XDG_CONFIG_HOME="$tmp/config" XDG_CACHE_HOME="$tmp/cache" \
XDG_DATA_HOME="$tmp/data" XDG_STATE_HOME="$tmp/state" \
QT_QPA_PLATFORM=offscreen \
    dbus-run-session -- "$bin" </dev/null >"$tmp/log" 2>&1 &
launcher_pid=$!

for _ in $(seq 1 40); do
    app_pid=$(find_app) || app_pid=""
    [ -n "$app_pid" ] && break
    sleep 0.5
done
if [ -z "$app_pid" ]; then
    echo "приложение не запустилось, вывод:" >&2
    tail -20 "$tmp/log" >&2
    exit 1
fi

for _ in $(seq 1 40); do
    child_pids=$(pgrep -P "$app_pid" 2>/dev/null | tr '\n' ' ')
    [ "$(echo $child_pids | wc -w)" -ge 3 ] && break
    sleep 0.5
done

echo "cloudmus-qt: pid $app_pid"
for pid in $child_pids; do
    printf '  бэкенд %s: %s\n' "$pid" "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
done

missing=""
for name in cloudmus_backend_local cloudmus_backend_yandex cloudmus_backend_ytmusic; do
    found=no
    for pid in $child_pids; do
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- "$name" && found=yes
    done
    [ "$found" = yes ] || missing="$missing бэкенд:$name"
done

echo "манифесты:"
for f in "$tmp"/config/cloudmus/backends.d/*.json; do
    [ -e "$f" ] || { missing="$missing манифесты"; break; }
    echo "  $(basename "$f"): $(cat "$f")"
done

# пути из манифестов должны существовать, иначе бэкенд не запустится
if command -v python3 >/dev/null; then
    python3 - "$tmp" <<'PY' || missing="$missing пути"
import json, glob, os, sys
for f in sorted(glob.glob(sys.argv[1] + "/config/cloudmus/backends.d/*.json")):
    d = json.load(open(f))
    for p in (d["argv"][0], d["icon"]):
        if not os.path.exists(p):
            print("  нет пути: " + p, file=sys.stderr)
            sys.exit(1)
PY
fi

if [ -n "$missing" ]; then
    echo "не сошлось:$missing" >&2
    tail -20 "$tmp/log" >&2
    exit 1
fi
echo "всё на месте: три бэкенда, три манифеста, пути существуют"
