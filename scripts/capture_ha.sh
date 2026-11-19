#!/usr/bin/env bash
# Capture real Home Assistant REST responses (status line, headers, body) into
# spec/fixtures/ha/ so the mock server can replay them 1:1.
# READ-ONLY: only GET /api/states/*, weather.get_forecasts (a read-only service
# with return_response) and requests that are rejected before doing anything.
# Never calls services that change state.
#   HA_URL=http://192.168.1.10:8123 HA_TOKEN=... scripts/capture_ha.sh [entity_id...]
set -euo pipefail
: "${HA_URL:?set HA_URL, e.g. http://homeassistant:8123}"
: "${HA_TOKEN:?set HA_TOKEN (long-lived access token)}"
WEATHER="${HA_WEATHER:-weather.forecast_dom}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/spec/fixtures/ha"
mkdir -p "$OUT/states" "$OUT/raw"
A=(-H "Authorization: Bearer $HA_TOKEN")
J=(-H "Content-Type: application/json")

cap() { # name, curl args... -> raw/<name>.http (headers + blank line + body)
  local name=$1; shift
  local h b; h=$(mktemp); b=$(mktemp)
  curl -sS -D "$h" -o "$b" "$@"
  # drop Date, hide the real HA address (it appears in WWW-Authenticate)
  { tr -d '\r' < "$h" | grep -v -i '^date:' | sed "s#$HA_URL#{HA_URL}#g"; cat "$b"; } > "$OUT/raw/$name.http"
  echo "$(head -1 "$h" | tr -d '\r')  $name"
  cp "$b" "$OUT/raw/$name.body"
  rm -f "$h" "$b"
}

ENTITIES=("$@")
[ ${#ENTITIES[@]} -eq 0 ] && ENTITIES=("$WEATHER")
for e in "${ENTITIES[@]}"; do
  curl -sS -f "${A[@]}" "$HA_URL/api/states/$e" > "$OUT/states/$e.json" && echo "state  $e"
done

cap api_root            "${A[@]}" "$HA_URL/api/"
cap state_not_found     "${A[@]}" "$HA_URL/api/states/sensor.homedash_does_not_exist"
cap unauthorized        -H "Authorization: Bearer invalid" "$HA_URL/api/states/$WEATHER"
cap forecast_hourly     "${A[@]}" "${J[@]}" -X POST -d "{\"entity_id\":\"$WEATHER\",\"type\":\"hourly\"}" "$HA_URL/api/services/weather/get_forecasts?return_response"
cap forecast_daily      "${A[@]}" "${J[@]}" -X POST -d "{\"entity_id\":\"$WEATHER\",\"type\":\"daily\"}"  "$HA_URL/api/services/weather/get_forecasts?return_response"
cap forecast_twice_daily "${A[@]}" "${J[@]}" -X POST -d "{\"entity_id\":\"$WEATHER\",\"type\":\"twice_daily\"}" "$HA_URL/api/services/weather/get_forecasts?return_response"
cap forecast_no_return_response "${A[@]}" "${J[@]}" -X POST -d "{\"entity_id\":\"$WEATHER\",\"type\":\"daily\"}" "$HA_URL/api/services/weather/get_forecasts"
cap service_not_found   "${A[@]}" "${J[@]}" -X POST -d '{}' "$HA_URL/api/services/homedash_nope/nope"
cap service_bad_json    "${A[@]}" "${J[@]}" -X POST -d '{bad' "$HA_URL/api/services/homeassistant/update_entity"
cap service_wrong_method "${A[@]}" "$HA_URL/api/services/homeassistant/update_entity"
cp "$OUT/raw/forecast_hourly.body" "$OUT/forecast_hourly.json"
cp "$OUT/raw/forecast_daily.body"  "$OUT/forecast_daily.json"
echo "done -> $OUT"
