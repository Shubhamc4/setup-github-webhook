#!/bin/bash

APP_NAME="${APP_NAME:-"Webhook"}"
PROJECT_PATH="${PROJECT_PATH:-$(pwd)}"
BRANCH="${BRANCH:-"main"}"
PAYLOAD_FILE="/tmp/$(date +%s)_payload.json"
LOG_FILE="/tmp/deploy.log"

get_ip() {
  local ip
  
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  
  if [ -z "$ip" ]; then
    ip=$(curl -s --connect-timeout 2 https://ifconfig.me || echo "Unknown IP")
  fi
  
  echo "$ip"
}

PUBLIC_IP=$(get_ip)

notify_deploy() {
  if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Cannot send Discord notification."
    return 1
  fi

  if [ -z "$DISCORD_WEBHOOK_URL" ]; then
    echo "Warning: DISCORD_WEBHOOK_URL is not set. Skipping notification."
    return 0
  fi

  local MSG="${1:-"No message provided"}"
  local COLOR="${2:-3066993}"
  local STATUS="${3:-"Unknown"}"

  local COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "N/A")
  local COMMIT_MSG=$(git log -1 --pretty=%B 2>/dev/null | head -n 1 | head -c 200 || echo "N/A")
  local COMMIT_AUTHOR=$(git log -1 --pretty=%an 2>/dev/null || echo "N/A")
  
  local REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
  local COMMIT_URL="N/A"
  if [ -n "$REMOTE_URL" ]; then
    local BASE_URL=$(echo "$REMOTE_URL" | sed -E 's|git@([^:]+):|https://\1/|; s|https://([^@]+)@|https://|; s|\.git$||')
    COMMIT_URL="${BASE_URL}/commit/$(git rev-parse HEAD 2>/dev/null)"
  fi

  jq -n \
    --arg srv "$APP_NAME" \
    --arg ip "$PUBLIC_IP" \
    --arg path "$PROJECT_PATH" \
    --arg stat "$STATUS" \
    --arg br "$BRANCH" \
    --arg hash "$COMMIT_HASH" \
    --arg url "$COMMIT_URL" \
    --arg auth "$COMMIT_AUTHOR" \
    --arg msg "$COMMIT_MSG" \
    --arg desc "$MSG" \
    --arg color "$COLOR" \
    '{
      username: "$srv Bot",
      embeds: [{
        title: "🚀 Automatic Deployment: \($srv)",
        description: $desc,
        color: ($color | tonumber),
        fields: [
          ["Server", $srv, true], ["IP", $ip, true],
          ["Path", "`\($path)`", false], ["Status", $stat, true],
          ["Branch", $br, true], ["Commit", "[\($hash)](\($url))", true],
          ["Author", $auth, true], ["Message", $msg, false]
        ] | map(select(.[1] != "") | {name: .[0], value: .[1], inline: .[2]}),
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        footer: {text: "Deploy System"}
      }]
    }' > "$PAYLOAD_FILE"

  if [ ! -f "$LOG_FILE" ]; then
    curl -s -X POST -H "Content-Type: application/json" -d @"$PAYLOAD_FILE" "$DISCORD_WEBHOOK_URL" > /dev/null 2>&1
  else
    curl -s -X POST -F "payload_json=<${PAYLOAD_FILE}" -F "file1=@$LOG_FILE" "$DISCORD_WEBHOOK_URL" > /dev/null 2>&1
    rm -f "$LOG_FILE"
  fi

  rm -f "$PAYLOAD_FILE" 
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  notify_deploy "$1" "$2" "$3"
fi
