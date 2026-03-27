#!/bin/bash

set -e

if ! [ -x "$(command -v sudo)" ]; then
  echo 'Error: sudo is not installed.' >&2
  exit 1
fi

#######################################
# 1. Install requirements
#######################################
echo "Installing requirements..."
sudo apt-get update -qq > /dev/null 2>&1 && sudo apt-get install -y -qq webhook jq curl git openssl > /dev/null 2>&1

#######################################
# 2. Open firewall port
#######################################
if sudo ufw status | grep -q "Status: active"; then
  echo "UFW is active. Opening port 9000..."
  sudo ufw allow 9000/tcp
else
  echo "UFW is not active. Skipping firewall rule configuration."
fi

#######################################
# 3. Paths + Project Info
#######################################
DEPLOY_BASE_PATH="/var/www/deploy-webhook"

read -p "Enter GitLab Repo SSH path (e.g., git@gitlab.com:user/repo.git): " REPO_PATH
REPO_NAME=$(basename "$REPO_PATH" .git)

read -p "Enter Deploy Webhook Base Path [$DEPLOY_BASE_PATH]: " input
DEPLOY_BASE_PATH=${input:-$DEPLOY_BASE_PATH}

read -p "Enter your project path (e.g., /var/www/$REPO_NAME): " PROJECT_PATH
PROJECT_NAME=$(basename "$PROJECT_PATH")

HOOK_SECRET=$(openssl rand -hex 16)
PUBLIC_IP=$(hostname -I | awk '{print $1}')
WEBHOOK_URL="http://${PUBLIC_IP}:9000/${PROJECT_NAME}"
SSH_FOLDER="$DEPLOY_BASE_PATH/ssh"

#######################################
# 4. SSH Key Generation (Deploy Key)
#######################################
SSH_PATH="$SSH_FOLDER/id_ed25519"
sudo mkdir -p "$SSH_FOLDER"
sudo chown -R "$USER:$USER" "$SSH_FOLDER"

if [ ! -f "$SSH_PATH" ]; then
    echo "Generating new SSH Deploy Key..."
    ssh-keygen -t ed25519 -C "gitlab-ci@$PUBLIC_IP" -f "$SSH_PATH" -N ""
fi

PUB_KEY=$(cat "${SSH_PATH}.pub")

echo "-------------------------------------------------------"
echo "🔑 ACTION REQUIRED: ADD DEPLOY KEY TO GITLAB"
echo "1. Go to your GitLab Repository -> Settings -> Repository -> Deploy Keys"
echo "2. Title: Webhook-Deploy-$PROJECT_NAME"
echo "3. Key:"
echo "$PUB_KEY"
echo "-------------------------------------------------------"
echo "🔔 WEBHOOK SETUP VALUES"
echo "Webhook URL:  $WEBHOOK_URL"
echo "Secret Token: $HOOK_SECRET"
echo "-------------------------------------------------------"
read -p "Press ENTER once the Deploy Key is added to GitLab..."

#######################################
# 5. Git Configuration
#######################################
read -p "Enter branch to deploy: " BRANCH_NAME
read -p "Enter Discord Webhook URL (Blank to skip): " DISCORD_URL

# Extract domain for SSH config (usually gitlab.com)
REPO_DOMAIN=$(echo "$REPO_PATH" | sed -E 's/.*@([^:]+).*/\1/')

# Configure SSH to use this specific key for this domain
# We use a custom SSH command in the redeploy script rather than modifying ~/.ssh/config globally
SSH_WRAPPER="$SSH_FOLDER/ssh_wrapper.sh"
cat > "$SSH_WRAPPER" <<EOF
#!/bin/bash
ssh -i "$SSH_PATH" -o "StrictHostKeyChecking=accept-new" "\$@"
EOF
chmod +x "$SSH_WRAPPER"

# Verify repo access
echo "Testing connection..."
if ! GIT_SSH="$SSH_WRAPPER" git ls-remote --heads "$REPO_PATH" "$BRANCH_NAME" | grep -q "$BRANCH_NAME"; then
  echo "❌ ERROR: Cannot access repo. Ensure the Deploy Key is added and has read access."
  exit 1
fi

#######################################
# 6. Initial Clone
#######################################
if [ -d "$PROJECT_PATH" ]; then
  if [ ! -d "$PROJECT_PATH/.git" ]; then
    echo "⚠️  WARNING: $PROJECT_PATH exists but is NOT a git repo."
    read -p "Delete directory and re-clone? (y/n): " CONFIRM
    [[ "$CONFIRM" == "y" ]] && sudo rm -rf "$PROJECT_PATH" || exit 1
  fi
fi

if [ ! -d "$PROJECT_PATH" ]; then
  GIT_SSH="$SSH_WRAPPER" git clone -b "$BRANCH_NAME" "$REPO_PATH" "$PROJECT_PATH"
fi

#######################################
# 7. Create Redeploy Script
#######################################
DEPLOY_SCRIPT="$DEPLOY_BASE_PATH/redeploy/$PROJECT_NAME.sh"
SERVER_NAME=$(hostname)
LOCAL_IP=$(hostname -I | awk '{print $1}')

cat > "$DEPLOY_SCRIPT" <<'EOF'
#!/bin/bash
set -e

# Force git to use the specific deploy key
export GIT_SSH="SSH_WRAPPER_PLACEHOLDER"
LOG_FILE="/tmp/PROJECT_NAME_PLACEHOLDER.log"
PAYLOAD_FILE="/tmp/$(date +%s)_payload.json"
DISCORD_WEBHOOK_URL="DISCORD_URL_PLACEHOLDER"
cd "PROJECT_PATH_PLACEHOLDER"

send_discord() {
  if [ -z "$DISCORD_WEBHOOK_URL" ]; then
    mv "$LOG_FILE" "DEPLOY_BASE_PATH_PLACEHOLDER/logs/PROJECT_NAME_PLACEHOLDER-$(date +%s).log"
    return
  fi
  local MSG="$1"
  local COLOR="$2"
  local STATUS="$3"

  local COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "N/A")
  local COMMIT_MSG=$(git log -1 --pretty=%B 2>/dev/null || echo "N/A")
  local COMMIT_AUTHOR=$(git log -1 --pretty=%an 2>/dev/null || echo "N/A")
  local COMMIT_URL="REPO_PATH_PLACEHOLDER/-/commit/$(git rev-parse HEAD 2>/dev/null || echo "")"

  echo $(jq -n \
    --arg title "🚀 Deployment: PROJECT_NAME_PLACEHOLDER" \
    --arg desc "$MSG" --arg status "$STATUS" --arg branch "BRANCH_NAME_PLACEHOLDER" \
    --arg hash "$COMMIT_HASH" --arg msg "$COMMIT_MSG" --arg auth "$COMMIT_AUTHOR" \
    --arg url "$COMMIT_URL" --arg srv "SERVER_NAME_PLACEHOLDER" --arg ip "LOCAL_IP_PLACEHOLDER" \
    --arg path "PROJECT_PATH_PLACEHOLDER" --arg color "$COLOR" \
    '{username: "\($srv) Bot", embeds: [{title: $title, description: $desc, color: ($color|tonumber), fields: [
      {name: "Server", value: $srv, inline: true}, {name: "IP", value: $ip, inline: true},
      {name: "Path", value: ("`" + $path + "`"), inline: false}, {name: "Status", value: $status, inline: true},
      {name: "Branch", value: $branch, inline: true}, {name: "Commit", value: "[\($hash)](\($url))", inline: true},
      {name: "Author", value: $auth, inline: true}, {name: "Message", value: $msg, inline: false}
    ], timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")), footer: {text: "Deploy System"}}]}'
  ) > "$PAYLOAD_FILE"

  curl -s -X POST \
    -F "payload_json=<${PAYLOAD_FILE}" \
    -F "file1=@$LOG_FILE" \
    "$DISCORD_WEBHOOK_URL" > /dev/null 2>&1
  
  rm -f "$LOG_FILE" "$PAYLOAD_FILE"
}

trap 'send_discord "❌ Failed at: \`$BASH_COMMAND\` (Exit: $?)" 15158332 "FAILED"' ERR

{
  git fetch origin "BRANCH_NAME_PLACEHOLDER"

  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

  if [ "$CURRENT_BRANCH" != "BRANCH_NAME_PLACEHOLDER" ]; then
      git checkout "BRANCH_NAME_PLACEHOLDER" || git checkout -b "BRANCH_NAME_PLACEHOLDER" --track origin/"BRANCH_NAME_PLACEHOLDER"
  fi

  git pull origin "BRANCH_NAME_PLACEHOLDER"

  CHANGED_FILES=$(git diff --name-only HEAD@{1} HEAD)

  # Post-deploy hooks
  if echo "$CHANGED_FILES" | grep -q "composer.json"; then
    echo "Composer.json updated. Running composer install..."
    composer install --no-dev --no-interaction --optimize-autoloader
  fi

  # Laravel specific
  if echo "$CHANGED_FILES" | grep -qE "database/migrations/"; then
    php artisan migrate --force
  fi

  if echo "$CHANGED_FILES" | grep -qE "package.json|resources/"; then
    if echo "$CHANGED_FILES" | grep -qE "package.json"; then
      npm ci # or yarn install --frozen-lockfile
    fi

    npm run build # or your specific build command
  fi

  if echo "$CHANGED_FILES" | grep -q "\.env\.example"; then
      echo "⚠️ .env.example changed. Check if your .env needs manual updates!"
  fi

  send_discord "🚀 Successfully deployed the code and built assets." 3066993 "SUCCESS"
} 2>&1 | tee -a "$LOG_FILE"
EOF

# Placeholder Replacements
sed -i "s|SSH_WRAPPER_PLACEHOLDER|$SSH_WRAPPER|g" "$DEPLOY_SCRIPT"
sed -i "s|PROJECT_PATH_PLACEHOLDER|$PROJECT_PATH|g" "$DEPLOY_SCRIPT"
sed -i "s|DISCORD_URL_PLACEHOLDER|$DISCORD_URL|g" "$DEPLOY_SCRIPT"
# Convert SSH git path to HTTP for Discord Link mapping
HTTP_REPO_LINK=$(echo "$REPO_PATH" | sed -E 's#git@([^:]+):#https://\1/#; s#\.git$##')
sed -i "s|REPO_PATH_PLACEHOLDER|$HTTP_REPO_LINK|g" "$DEPLOY_SCRIPT"
sed -i "s|PROJECT_NAME_PLACEHOLDER|$PROJECT_NAME|g" "$DEPLOY_SCRIPT"
sed -i "s|BRANCH_NAME_PLACEHOLDER|$BRANCH_NAME|g" "$DEPLOY_SCRIPT"
sed -i "s|SERVER_NAME_PLACEHOLDER|$SERVER_NAME|g" "$DEPLOY_SCRIPT"
sed -i "s|LOCAL_IP_PLACEHOLDER|$LOCAL_IP|g" "$DEPLOY_SCRIPT"
sed -i "s|DEPLOY_BASE_PATH_PLACEHOLDER|$DEPLOY_BASE_PATH|g" "$DEPLOY_SCRIPT"

chmod +x "$DEPLOY_SCRIPT"

#######################################
# 8. Webhook & Systemd
#######################################
HOOKS_FILE="$DEPLOY_BASE_PATH/hooks.json"
NEW_HOOK=$(jq -n --arg id "$PROJECT_NAME" --arg cmd "$DEPLOY_SCRIPT" --arg dir "$PROJECT_PATH" --arg secret "$HOOK_SECRET" --arg ref "refs/heads/$BRANCH_NAME" \
'{id: $id, "execute-command": $cmd, "command-working-directory": $dir, "trigger-rule": {"and": [{"match": {"type": "value", "value": "push", "parameter": {"source": "payload", "name": "object_kind"}}}, {"match": {"type": "value", "value": $ref, "parameter": {"source": "payload", "name": "ref"}}}, {"match": {"type": "value", "value": $secret, "parameter": {"source": "header", "name": "X-Gitlab-Token"}}}]}}')

if [ -f "$HOOKS_FILE" ]; then
  jq --argjson hook "$NEW_HOOK" 'map(select(.id != $hook.id)) + [$hook]' "$HOOKS_FILE" > "$HOOKS_FILE.tmp" && mv "$HOOKS_FILE.tmp" "$HOOKS_FILE"
else
  echo "$NEW_HOOK" | jq -s '.' > "$HOOKS_FILE"
fi

sudo bash -c "cat <<EOF > /etc/systemd/system/webhook.service
[Unit]
Description=Git Webhook Listener
After=network.target

[Service]
ExecStart=/usr/bin/webhook \
  -hooks $HOOKS_FILE \
  -hotreload \
  -logfile $DEPLOY_BASE_PATH/webhook.log \
  -verbose \
  -urlprefix ""
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable webhook
sudo systemctl restart webhook

echo "✅ SETUP COMPLETE"

echo "-------------------------------------------------------"
echo "🔧 NGINX CONFIGURATION GUIDE (Optional)"
echo "To expose the webhook securely, it's recommended to set up a reverse proxy with Nginx. Here's a sample configuration snippet:"
echo "-------------------------------------------------------"
echo "server {
  listen 80;
  server_name your-domain.com;

  location /webhooks/ {
    # Forward the request to the local webhook service
    proxy_pass http://127.0.0.1:9000/;

    # Standard proxy headers
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # Optional: Limit access to specific IP ranges (e.g., GitHub IPs)
    # allow 140.82.112.0/20;
    # deny all;
  }
}"
echo "-------------------------------------------------------"
echo "Make sure to replace 'your-domain.com' with your actual domain and set up SSL (e.g., using Let's Encrypt) for secure communication. After updating your Nginx configuration, reload Nginx to apply the changes:"
echo "sudo nginx -s reload"
echo "Also update the webhook url in gitlab repo."
echo "-------------------------------------------------------"
echo "🔐 SECURITY TIP: LIMITING WEBHOOK ACCESS"
echo "Edit the webhook systemd service to include an IP allow list for enhanced security. You can modify the ExecStart line to include the -ip flag:"
echo "ExecStart=/usr/bin/webhook -hooks $HOOKS_FILE -hotreload -port 9000 -ip \"127.0.0.1\" -urlprefix \"\""
