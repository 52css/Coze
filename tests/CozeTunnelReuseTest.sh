#!/bin/zsh
set -euo pipefail

# Manual end-to-end check: this intentionally needs a live SSH tunnel matching
# COZE_TUNNEL_CONFIG. Pure process matching is covered by CozeIdleSessionTests.
app_path="${1:?Usage: CozeTunnelReuseTest.sh /path/to/Coze.app (manual; requires a live configured tunnel)}"
app_path="${app_path:A}"
executable_path="$app_path/Contents/MacOS/Coze"
config_path="${COZE_TUNNEL_CONFIG:-$HOME/.coze/tunnel.json}"

route_rows="$(/usr/bin/python3 -c 'import json,sys
with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
for route in config.get("routes", []):
    print("{}\t{}".format(int(route["localPort"]), route.get("name", "服务")))' "$config_path")"

if [[ -z "$route_rows" ]]; then
    print -u2 "FAIL: tunnel configuration has no services"
    exit 1
fi

typeset -a service_names
while IFS=$'\t' read -r port service; do
    curl --silent --show-error --max-time 5 --output /dev/null "http://127.0.0.1:$port/"
    service_names+=("$service")
done <<< "$route_rows"

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
for _ in {1..40}; do
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

if [[ "$ui" != *"static text ●  已连接"* ]]; then
    print -u2 "FAIL: an existing healthy SSH tunnel was shown as disconnected"
    exit 1
fi

if [[ "$ui" != *"button 断开"* ]]; then
    print -u2 "FAIL: the existing tunnel was not adopted by the new Coze process"
    exit 1
fi

for service in "${service_names[@]}"; do
    if [[ "$ui" != *"button $service"* ]]; then
        print -u2 "FAIL: missing direct service button: $service"
        exit 1
    fi
done

for service in "${service_names[@]:0:2}"; do
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $pid) to click button \"$service\" of scroll area 1 of window 1"
done

ui_after_clicks="$(osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $pid) to get entire contents of window 1")"
if [[ "$ui_after_clicks" != *"static text ●  已连接"* || "$ui_after_clicks" != *"button 断开"* ]]; then
    print -u2 "FAIL: switching services caused Coze to request SSH authentication again"
    exit 1
fi

print "PASS: Coze reused one tunnel while opening configured services consecutively"
