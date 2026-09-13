#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

denylist="${SSHMANAGER_LEAK_DENYLIST:-}"
if [[ -z "$denylist" ]]; then
    echo "error: set SSHMANAGER_LEAK_DENYLIST to the path of the denylist file" >&2
    exit 2
fi
if [[ ! -f "$denylist" || ! -r "$denylist" ]]; then
    echo "error: SSHMANAGER_LEAK_DENYLIST does not name a readable file" >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

patterns=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
    patterns+=("$line")
done <"$denylist"

if [[ ${#patterns[@]} -eq 0 ]]; then
    echo "error: the denylist holds no patterns" >&2
    exit 2
fi

hits=0

report() {
    local pattern="$1" where="$2"
    printf 'leak [%s] %s\n' "$pattern" "$where"
    hits=$((hits + 1))
}

report_lines() {
    local pattern="$1" source="$2" line
    while IFS= read -r line; do
        report "$pattern" "$source ${line:0:240}"
    done
}

echo "==> tracked files"
for pattern in "${patterns[@]}"; do
    report_lines "$pattern" "file" < <(git grep -F -i -n -I -e "$pattern" -- . || true)
    report_lines "$pattern" "path" < <(git ls-files | grep -F -i -e "$pattern" || true)
done

echo "==> history"
for pattern in "${patterns[@]}"; do
    report_lines "$pattern" "diff" < <(git log --all --text -i -F -S "$pattern" --format='%h %s' || true)
    report_lines "$pattern" "message" < <(git log --all -i -F --grep="$pattern" --format='%h %s' || true)
    report_lines "$pattern" "identity" < <(git log --all --format='%h %an <%ae> %cn <%ce>' | grep -F -i -e "$pattern" || true)
    report_lines "$pattern" "ref" < <(git for-each-ref --format='%(refname) %(contents)' | grep -F -i -e "$pattern" || true)
done

echo "==> media"
media=()
while IFS= read -r -d '' file; do
    media+=("$file")
done < <(git ls-files -z -- ':(icase)*.png' ':(icase)*.jpg' ':(icase)*.jpeg' ':(icase)*.mp4' \
    ':(icase)*.mov' ':(icase)*.svg' ':(icase)*.pdf' ':(icase)*.webp' ':(icase)*.avif' ':(icase)*.gif')

index=0
for file in ${media[@]+"${media[@]}"}; do
    [[ -f "$file" ]] || continue
    dump="$work/media-$index"
    strings -a -n 4 "$file" >"$dump" 2>/dev/null || true
    if command -v exiftool >/dev/null 2>&1; then
        exiftool -a -u -G1 "$file" >>"$dump" 2>/dev/null || true
    fi
    for pattern in "${patterns[@]}"; do
        if grep -F -i -q -e "$pattern" "$dump"; then
            report "$pattern" "media $file"
        fi
    done
    index=$((index + 1))
done

echo "scanned ${#media[@]} media files against ${#patterns[@]} patterns"
if [[ $hits -gt 0 ]]; then
    echo "leak-check: $hits matches" >&2
    exit 1
fi
echo "leak-check: clean"
