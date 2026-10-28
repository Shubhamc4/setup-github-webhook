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

DEPLOY_BASE_PATH="/var/www/deploy-webhook"
read -p "Enter Deploy Webhook Base Path [$DEPLOY_BASE_PATH]: " input
DEPLOY_BASE_PATH=${input:-$DEPLOY_BASE_PATH}
SSH_FOLDER="$DEPLOY_BASE_PATH/ssh"
SSH_PATH="$SSH_FOLDER/id_ed25519"

read -p "Enter GitLab Repo SSH path (e.g., git@gitlab.com:user/repo.git): " REPO_PATH
read -p "Enter branch to deploy: " BRANCH_NAME
REPO_NAME=$(basename "$REPO_PATH" .git)
PUBLIC_IP=$(hostname -I | awk '{print $1}')

#######################################
# 3. Conditional SSH Key Generation & Wrapper
#######################################
if [ ! -d "$SSH_FOLDER" ] || [ ! -f "$SSH_PATH" ]; then
    echo "SSH folder or key not found. Setting up..."
    sudo mkdir -p "$SSH_FOLDER"
    sudo chown -R "$USER:$USER" "$SSH_FOLDER"

    if [ ! -f "$SSH_PATH" ]; then
        echo "Generating new SSH Deploy Key..."
        ssh-keygen -t ed25519 -C "gitlab-ci@$PUBLIC_IP" -f "$SSH_PATH" -N ""
    fi
else
    echo "Existing SSH folder and key found. Skipping generation."
fi

SSH_WRAPPER="$SSH_FOLDER/ssh_wrapper.sh"
cat > "$SSH_WRAPPER" <<EOF
#!/bin/bash
ssh -i "$SSH_PATH" -o "StrictHostKeyChecking=accept-new" "\$@"
EOF
chmod +x "$SSH_WRAPPER"

PUB_KEY=$(cat "${SSH_PATH}.pub")

echo "-------------------------------------------------------"
echo "🔑 ACTION REQUIRED: ADD DEPLOY KEY TO GITLAB"
echo "1. Go to your GitLab Repository -> Settings -> Repository -> Deploy Keys"
echo "2. Title: Webhook-Deploy-$REPO_NAME"
echo "3. Key:"
echo "$PUB_KEY"
echo "-------------------------------------------------------"
read -p "Press ENTER once the Deploy Key is added to GitLab..."

#######################################
# 4. Verify repo access
#######################################
echo "Testing connection..."
if ! GIT_SSH="$SSH_WRAPPER" git ls-remote --heads "$REPO_PATH" "$BRANCH_NAME" | grep -q "$BRANCH_NAME"; then
  echo "❌ ERROR: Cannot access repo. Ensure the Deploy Key is added and has read access."
  exit 1
fi

#######################################
# 5. Paths + Project Info
#######################################
read -p "Enter your project path (e.g., /var/www/$REPO_NAME): " PROJECT_PATH
PROJECT_PATH=${PROJECT_PATH:-/var/www/$REPO_NAME}
PROJECT_NAME=$(basename "$PROJECT_PATH")

HOOK_SECRET=$(openssl rand -hex 16)
WEBHOOK_URL="http://${PUBLIC_IP}:9000/${PROJECT_NAME}"

echo "-------------------------------------------------------"
echo "🔔 WEBHOOK SETUP VALUES"
echo "Webhook URL:  $WEBHOOK_URL"
echo "Secret Token: $HOOK_SECRET"
echo "-------------------------------------------------------"
read -p "Enter Discord Webhook URL (Blank to skip): " DISCORD_URL

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

mkdir -p "$DEPLOY_BASE_PATH/redeploy"

cat > "$DEPLOY_SCRIPT" <<'EOF'
#!/bin/bash
set -e

export GIT_SSH="SSH_WRAPPER_PLACEHOLDER"
export GIT_TERMINAL_PROMPT=0
export COMPOSER_ALLOW_SUPERUSER=1

export APP_NAME="PROJECT_NAME_PLACEHOLDER"
export BRANCH="BRANCH_NAME_PLACEHOLDER"
export PROJECT_PATH="PROJECT_PATH_PLACEHOLDER"
export DISCORD_WEBHOOK_URL="DISCORD_URL_PLACEHOLDER"
export LOG_FILE="/tmp/deploy.log"

source <(curl -sL https://raw.githubusercontent.com/Shubhamc4/setup-github-webhook/main/discord_notify.sh)

cd "$PROJECT_PATH"

trap 'notify_deploy "❌ Failed at: \`$BASH_COMMAND\` (Exit: $?)" 15158332 "FAILED"' ERR

{
  git fetch origin "$BRANCH"

  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

  if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
      git checkout "$BRANCH" || git checkout -b "$BRANCH" --track origin/"$BRANCH"
  else
    git reset --hard HEAD
    git clean -fd
  fi

  git pull origin "$BRANCH"

  CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD)

  # Post-deploy hooks
  if echo "$CHANGED_FILES" | grep -q "composer.json"; then
    echo "Composer.json updated. Running composer install..."
    composer install --no-dev --no-interaction --optimize-autoloader
  fi

  if echo "$CHANGED_FILES" | grep -qE "package.json|resources/|src/"; then
    if echo "$CHANGED_FILES" | grep -qE "package.json"; then
      npm ci
    fi

    npm run build
  fi

  if echo "$CHANGED_FILES" | grep -q "\.env\.example"; then
      echo "⚠️ .env.example changed. Check if your .env needs manual updates!"
  fi

  notify_deploy "🚀 Successfully deployed the code and built assets." 3066993 "SUCCESS"
} 2>&1 | tee -a "$LOG_FILE"
EOF

# Placeholder Replacements
APP_NAME_FORMATTED="${PROJECT_NAME//-/ }"
sed -i "s|SSH_WRAPPER_PLACEHOLDER|$SSH_WRAPPER|g" "$DEPLOY_SCRIPT"
sed -i "s|PROJECT_PATH_PLACEHOLDER|$PROJECT_PATH|g" "$DEPLOY_SCRIPT"
sed -i "s|DISCORD_URL_PLACEHOLDER|$DISCORD_URL|g" "$DEPLOY_SCRIPT"
# Convert SSH git path to HTTP for Discord Link mapping
HTTP_REPO_LINK=$(echo "$REPO_PATH" | sed -E 's#git@([^:]+):#https://\1/#; s#\.git$##')
sed -i "s|REPO_PATH_PLACEHOLDER|$HTTP_REPO_LINK|g" "$DEPLOY_SCRIPT"
sed -i "s|PROJECT_NAME_PLACEHOLDER|${APP_NAME_FORMATTED^}|g" "$DEPLOY_SCRIPT"
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
ExecStart=/usr/bin/webhook \\
-hooks $HOOKS_FILE \\
-hotreload \\
-logfile $DEPLOY_BASE_PATH/webhook.log \\
-verbose \\
-urlprefix \"\"
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable webhook
sudo systemctl restart webhook

echo "✅ SETUP COMPLETE"
