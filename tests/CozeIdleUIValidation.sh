#!/bin/zsh
set -euo pipefail

app_path="${1:?Usage: CozeIdleUIValidation.sh /path/to/Coze.app}"
app_path="${app_path:A}"
executable_path="$app_path/Contents/MacOS/Coze"

/usr/bin/open -n "$app_path"
pid=""
for _ in {1..50}; do
    pid="$(pgrep -f -x "$executable_path" | head -1 || true)"
    [[ -n "$pid" ]] && break
    sleep 0.1
done
if [[ -z "$pid" ]]; then
    print -u2 "FAIL: Coze process did not launch"
    exit 1
fi
trap 'kill "$pid" 2>/dev/null || true' EXIT

window_ready=false
for _ in {1..50}; do
    if osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $pid) to get (count of windows)" 2>/dev/null | grep -q '^1$'; then
        window_ready=true
        break
    fi
    sleep 0.2
done

if [[ "$window_ready" != true ]]; then
    print -u2 "FAIL: Coze did not create its main window"
    exit 1
fi

ui="$(osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $pid) to get entire contents of window 1")"
for title in "15 分钟" "30 分钟" "60 分钟" "关闭"; do
    if [[ "$ui" != *"checkbox $title"* ]]; then
        print -u2 "FAIL: missing visible idle control: $title"
        exit 1
    fi
done

selected="$(osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $pid) to get value of checkbox \"30 分钟\" of scroll area 1 of window 1")"
if [[ "$selected" != "1" ]]; then
    print -u2 "FAIL: 30 minutes is not the default selected timeout"
    exit 1
fi

if [[ "$ui" != *"后自动断开"* && "$ui" != *"连接后开始计时"* ]]; then
    print -u2 "FAIL: idle countdown status is not visible"
    exit 1
fi

if [[ "$ui" == *"后自动断开"* ]]; then
    if [[ "$ui" != *"button 续期"* ]]; then
        print -u2 "FAIL: connected tunnel is missing visible idle control: 续期"
        exit 1
    fi
    sleep 2
    ui_before_renew="$(osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $pid) to get entire contents of window 1")"
    before_text="$(print -r -- "$ui_before_renew" | rg -o '[0-9]{2}:[0-9]{2} 后自动断开' | head -1)"
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $pid) to click button \"续期\" of scroll area 1 of window 1" >/dev/null
    ui_after_renew="$(osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $pid) to get entire contents of window 1")"
    after_text="$(print -r -- "$ui_after_renew" | rg -o '[0-9]{2}:[0-9]{2} 后自动断开' | head -1)"
    before_clock="${before_text%% *}"
    after_clock="${after_text%% *}"
    before_seconds=$((10#${before_clock%%:*} * 60 + 10#${before_clock##*:}))
    after_seconds=$((10#${after_clock%%:*} * 60 + 10#${after_clock##*:}))
    if (( after_seconds <= before_seconds )); then
        print -u2 "FAIL: clicking 续期 did not restore the idle countdown"
        exit 1
    fi
fi

print "PASS: idle timeout controls and countdown are visible with 30 minutes selected"
