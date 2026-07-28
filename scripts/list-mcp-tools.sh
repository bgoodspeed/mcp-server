#!/usr/bin/env bash
#
# Lists the tools exposed by the Burp MCP server over its HTTP+SSE transport.
#
# The MCP SSE transport is asynchronous: you open an event stream with
# `GET /` (this SDK mounts it at the root), which hands back a per-session POST
# endpoint via an `event: endpoint` / `data: ?sessionId=...` message, and every
# JSON-RPC *response* is delivered back on the SSE stream rather than in the POST
# response body (POSTs just get 202 Accepted). So this script keeps the stream
# open in the background and correlates responses by id.
#
# Usage: scripts/list-mcp-tools.sh [host:port]   (default 127.0.0.1:9876)

set -euo pipefail

BASE="http://${1:-127.0.0.1:9876}"
STREAM="$(mktemp)"
SSE_PID=""

cleanup() {
  [[ -n "$SSE_PID" ]] && kill "$SSE_PID" 2>/dev/null || true
  rm -f "$STREAM"
}
trap cleanup EXIT

# Wait until $STREAM contains a `data:` line matching regex $1 (up to ~10s),
# then print the matching JSON payload.
wait_for_data() {
  local pattern="$1" i
  for ((i = 0; i < 100; i++)); do
    local line
    # SSE lines are CRLF-terminated; strip the trailing CR or it corrupts URLs/JSON.
    line=$(grep -a '^data: ' "$STREAM" 2>/dev/null | sed 's/^data: //' | tr -d '\r' | grep -E "$pattern" | tail -1 || true)
    if [[ -n "$line" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

post() {
  # POST a JSON-RPC message to the session endpoint. Response arrives on the stream.
  curl -s -o /dev/null -X POST "$POST_URL" \
    -H 'Content-Type: application/json' \
    -d "$1"
}

echo "Opening SSE stream at $BASE/ ..."
curl -sN "$BASE/" >"$STREAM" 2>/dev/null &
SSE_PID=$!

# The first SSE event is `event: endpoint` / `data: ?sessionId=...` (a reference
# resolved against the SSE URL). Strip a leading slash if one is present so both
# `?sessionId=...` and `/message?sessionId=...` forms resolve correctly.
MSG_PATH=""
for ((i = 0; i < 100; i++)); do
  MSG_PATH=$(grep -a '^data: ' "$STREAM" 2>/dev/null | sed 's/^data: //' | tr -d '\r' | grep -E '/message|sessionId' | head -1 || true)
  [[ -n "$MSG_PATH" ]] && break
  sleep 0.1
done

if [[ -z "$MSG_PATH" ]]; then
  echo "ERROR: never received the session endpoint. Is the server running at $BASE?" >&2
  exit 1
fi
POST_URL="${BASE}/${MSG_PATH#/}"
echo "Session endpoint: $POST_URL"

# 1) initialize (id 1)
post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl-list-tools","version":"1.0.0"}}}'
wait_for_data '"id":1' >/dev/null || { echo "ERROR: no initialize response" >&2; exit 1; }

# 2) initialized notification (no id)
post '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# 3) tools/list (id 2)
post '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
TOOLS_JSON=$(wait_for_data '"id":2') || { echo "ERROR: no tools/list response" >&2; exit 1; }

echo
echo "Tools exposed by the server:"
echo "$TOOLS_JSON" | jq -r '.result.tools[].name' | sort | sed 's/^/  - /'

echo
COUNT=$(echo "$TOOLS_JSON" | jq '.result.tools | length')
echo "Total: $COUNT tools"

echo
echo "Session-handling tools present?"
for t in get_session_handling_config set_session_handling_config; do
  if echo "$TOOLS_JSON" | jq -e --arg n "$t" '.result.tools[] | select(.name == $n)' >/dev/null; then
    echo "  ✓ $t"
  else
    echo "  ✗ $t  (MISSING)"
  fi
done
