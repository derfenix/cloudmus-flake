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

# Токен нужен только чтобы не упираться в лимит анонимных запросов на раннере; в
# отсутствие переменных запрос уходит анонимно. Значение нигде не печатается.
auth=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
elif [ -n "${GH_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $GH_TOKEN")
fi

latest=$(
    curl -fsSL "${auth[@]}" -H 'Accept: application/vnd.github+json' \
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

# Хеш попадает в flake.nix, поэтому проверяем его форму до любой записи: иначе при
# странном ответе prefetch туда уехало бы, например, hash = "".
python3 - "$hash" <<'PY' || exit 1
import base64, re, sys
value = sys.argv[1]
match = re.fullmatch(r'sha256-([A-Za-z0-9+/]+={0,2})', value)
if match is None:
    sys.exit(f"хеш не в формате sha256-SRI: {value!r} — файл не тронут")
try:
    raw = base64.b64decode(match.group(1), validate=True)
except Exception as exc:
    sys.exit(f"в хеше не base64: {value!r} ({exc}) — файл не тронут")
if len(raw) != 32:
    sys.exit(f"в хеше {len(raw)} байт вместо 32 — файл не тронут")
PY

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
