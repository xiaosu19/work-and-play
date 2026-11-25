#!/bin/bash
set -euo pipefail
project="$(cd -- "$(dirname -- "$0")/.." && pwd)"
app="$(cd -- "${1:-$project/dist/WorkAndPlay.app}" && pwd)"
extension="$app/Contents/Resources/chrome-extension/manifest.json"
id="$(plutil -extract key raw -o - "$extension" | base64 -D | shasum -a 256 | cut -c 1-32 | tr '0123456789abcdef' 'abcdefghijklmnop')"
[[ "$id" =~ ^[a-p]{32}$ ]] || { printf '扩展 ID 无效。\n' >&2; exit 1; }

register() (
    local directory="$1/NativeMessagingHosts"
    local host="$app/Contents/Helpers/$2"
    local name=local.workandplay.chrome
    [ -x "$host" ] || { printf '未找到连接器 %s\n' "$2" >&2; exit 1; }
    mkdir -p "$directory"
    local tmp
    tmp="$(mktemp "$directory/.$name.XXXXXX")"
    trap 'rm -f -- "$tmp"' EXIT
    plutil -create xml1 "$tmp"
    plutil -insert name -string "$name" "$tmp"
    plutil -insert description -string "工时簿本机连接器" "$tmp"
    plutil -insert type -string stdio "$tmp"
    plutil -insert path -string "$host" "$tmp"
    plutil -insert allowed_origins -json "[\"chrome-extension://$id/\"]" "$tmp"
    plutil -convert json "$tmp"
    mv -- "$tmp" "$directory/$name.json"
)

browser="${WORKANDPLAY_BROWSER:-}"
if [ -z "$browser" ]; then
    if [ -n "${WORKANDPLAY_CHROME_USER_DATA_DIRECTORY:-}" ]; then
        browser=chrome
    elif [ -n "${WORKANDPLAY_EDGE_USER_DATA_DIRECTORY:-}" ]; then
        browser=edge
    else
        browser=both
    fi
fi
case "$browser" in
    chrome|edge|both) ;;
    *) printf '浏览器选项应为 chrome、edge 或 both。\n' >&2; exit 1 ;;
esac

if [ "$browser" != edge ]; then
    register "${WORKANDPLAY_CHROME_USER_DATA_DIRECTORY:-$HOME/Library/Application Support/Google/Chrome}" ChromeNativeHost
fi
if [ "$browser" != chrome ]; then
    register "${WORKANDPLAY_EDGE_USER_DATA_DIRECTORY:-$HOME/Library/Application Support/Microsoft Edge}" EdgeNativeHost
fi
printf '扩展 ID：%s\n扩展目录：%s\n' "$id" "$(dirname -- "$extension")"
