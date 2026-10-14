#!/usr/bin/env bash
# Двигает пин CloudMus в flake.nix до последнего релиза cloudmus/cloudmus.
#
# Трогает только этот пин. Пин библиотеки yandex-music остаётся ручным: у неё между
# версиями меняются зависимости и extras, и ошибиться там дороже.
#
# Ничего не коммитит: это делает .github/workflows/update.yml, причём только после
# успешной сборки. Запускать можно и руками — тогда файлы просто изменятся.
set -euo pipefail

cd "$(dirname "$0")/.."
flake=flake.nix
readme=README.md
repo=${CLOUDMUS_REPO:-cloudmus/cloudmus}

command -v nix >/dev/null || { echo "нет nix в PATH" >&2; exit 1; }

current=$(sed -n 's/^      version = "\([^"]*\)";$/\1/p' "$flake")
[ -n "$current" ] || { echo "не нашёл пин CloudMus в $flake" >&2; exit 1; }

latest=$(
    curl -fsSL -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$repo/releases/latest" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'
)
latest=${latest#v}
[ -n "$latest" ] || { echo "GitHub не вернул тег" >&2; exit 1; }

echo "пин: $current, последний релиз: $latest"
if [ "$latest" = "$current" ]; then
    echo "менять нечего"
    exit 0
fi

url="https://github.com/$repo/archive/refs/tags/$latest.tar.gz"
echo "считаю хеш по скачанному архиву: $url"
hash=$(nix store prefetch-file --unpack --json "$url" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["hash"])')
echo "хеш: $hash"

python3 - "$flake" "$readme" "$current" "$latest" "$hash" <<'PY'
import pathlib, re, sys

flake, readme, old, new, digest = sys.argv[1:6]

def exactly_one(pattern, text, what):
    found = re.findall(pattern, text, re.M)
    if len(found) != 1:
        sys.exit(f"{what}: совпадений {len(found)}, ожидалось одно — файл не тронут")

text = pathlib.Path(flake).read_text()
exactly_one(r'^      version = "%s";$' % re.escape(old), text, "пин версии CloudMus")
exactly_one(r'^        hash = "sha256-[A-Za-z0-9+/=]+";$', text, "хеш src")
text = re.sub(r'^      version = "%s";$' % re.escape(old),
              '      version = "%s";' % new, text, count=1, flags=re.M)
text = re.sub(r'^        hash = "sha256-[A-Za-z0-9+/=]+";$',
              '        hash = "%s";' % digest, text, count=1, flags=re.M)
pathlib.Path(flake).write_text(text)
print(f"{flake}: {old} -> {new}")

notes = pathlib.Path(readme).read_text()
if f"CloudMus {old}" in notes:
    pathlib.Path(readme).write_text(notes.replace(f"CloudMus {old}", f"CloudMus {new}", 1))
    print(f"{readme}: обновил упоминание версии")
else:
    print(f"{readme}: упоминания 'CloudMus {old}' нет, оставил как есть", file=sys.stderr)
PY

echo "готово; сборку проверяет workflow перед коммитом"
