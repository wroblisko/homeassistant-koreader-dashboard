#!/usr/bin/env bash
# Starts the mock on a spare port and checks it replays the captured real-HA
# responses 1:1 (status line, headers except Date, body bytes), then exercises
# a simulated action. Exit 1 on any difference.
set -uo pipefail
cd "$(dirname "$0")/.."
PORT=${PORT:-18123}; B=http://127.0.0.1:$PORT
A=(-H "Authorization: Bearer mock-token"); J=(-H "Content-Type: application/json")
FAIL=0
start(){ python3 scripts/mock_ha.py --port $PORT --quiet "$@" & PID=$!; for _ in $(seq 50); do curl -s -o /dev/null $B/__mock/calls && return; sleep 0.1; done; }
stop(){ kill $PID 2>/dev/null; wait $PID 2>/dev/null; }
ok(){ echo "SAME  $1"; }; bad(){ echo "DIFF  $1"; FAIL=1; }
cmp_raw(){ local name=$1; shift
  local got exp; got=$(curl -s -D - "$@" | tr -d '\r' | grep -v -i '^date:')
  exp=$(cat spec/fixtures/ha/raw/$name.http); exp=${exp//\{HA_URL\}/$B}
  if [ "$got" = "$exp" ]; then ok "$name"; else bad "$name"; diff <(echo "$exp") <(echo "$got"); fi; }

start --no-shift
cmp_raw api_root "${A[@]}" $B/api/
cmp_raw state_not_found "${A[@]}" $B/api/states/sensor.homedash_does_not_exist
cmp_raw unauthorized -H "Authorization: Bearer invalid" $B/api/states/weather.forecast_dom
cmp_raw forecast_hourly "${A[@]}" "${J[@]}" -X POST -d '{"entity_id":"weather.forecast_dom","type":"hourly"}' "$B/api/services/weather/get_forecasts?return_response"
cmp_raw forecast_daily "${A[@]}" "${J[@]}" -X POST -d '{"entity_id":"weather.forecast_dom","type":"daily"}' "$B/api/services/weather/get_forecasts?return_response"
cmp_raw forecast_twice_daily "${A[@]}" "${J[@]}" -X POST -d '{"entity_id":"weather.forecast_dom","type":"twice_daily"}' "$B/api/services/weather/get_forecasts?return_response"
cmp_raw forecast_no_return_response "${A[@]}" "${J[@]}" -X POST -d '{"entity_id":"weather.forecast_dom","type":"daily"}' "$B/api/services/weather/get_forecasts"
cmp_raw service_not_found "${A[@]}" "${J[@]}" -X POST -d '{}' $B/api/services/homedash_nope/nope
cmp_raw service_bad_json "${A[@]}" "${J[@]}" -X POST -d '{bad' $B/api/services/homeassistant/update_entity
cmp_raw service_wrong_method "${A[@]}" $B/api/services/homeassistant/update_entity
for f in spec/fixtures/ha/states/*.json; do e=$(basename "$f" .json)
  curl -s "${A[@]}" "$B/api/states/$e" | cmp -s - "$f" && ok "state $e" || bad "state $e"; done
stop

echo "-- live mode: shifted forecast + simulated garage script"
start
first=$(curl -s "${A[@]}" "${J[@]}" -X POST -d '{"entity_id":"weather.forecast_dom","type":"hourly"}' "$B/api/services/weather/get_forecasts?return_response" | python3 -c 'import sys,json;print(json.load(sys.stdin)["service_response"]["weather.forecast_dom"]["forecast"][0]["datetime"])')
echo "first hourly slot: $first (now UTC $(date -u +%H:%M))"
resp=$(curl -s "${A[@]}" "${J[@]}" -X POST -d '{"entity_id":"script.otworz_garaz"}' $B/api/services/script/turn_on)
echo "script.turn_on -> $(echo "$resp" | python3 -c 'import sys,json;print([(s["entity_id"],s["state"]) for s in json.load(sys.stdin)])')"
g0=$(curl -s "${A[@]}" $B/api/states/binary_sensor.brama_garazowa | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')
sleep 4.5
g1=$(curl -s "${A[@]}" $B/api/states/binary_sensor.brama_garazowa | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')
echo "gate: $g0 -> $g1"; [ "$g0" = off ] && [ "$g1" = on ] && ok "garage rule" || bad "garage rule"
curl -s $B/__mock/calls | python3 -c 'import sys,json;print("calls:",[c["service"] for c in json.load(sys.stdin)])'
stop
exit $FAIL
