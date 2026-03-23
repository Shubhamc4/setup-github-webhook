# GitLab Webhook Auto-Deploy Script

Automated deployment system for GitLab repositories using [adnanh/webhook](https://github.com/adnanh/webhook). This script handles Git synchronizationvia SSH Deploy Keys, dependency installation (PHP/Node), and Discord notifications.

## Features

- **Automated Setup**: Installs dependencies (`webhook`, `jq`, `git`, etc.), sets up firewall, and configures systemd.
- **SSH Key Authentication**: Uses dedicated Ed25519 Deploy Keys for secure, repository-specific access. No personal tokens required.
- **Smart Deployment**: Checks git hashes before pulling to prevent redundant operations.
- **Rich Notifications**: Sends detailed deployment status to Discord (Commit hash, message, author, status).
- **Dependency Management**: Detects `package.json` or `composer.json` and runs the appropriate install commands automatically.
- **Isolated Configs**: Supports multiple projects by creating scoped directories for keys and scripts.

## Prerequisites

- Ubuntu/Debian server
- Sudo privileges
- A GitLab Repository (Private or Public)

## Installation

### 1. Run the Script

Run as a **standard user** (not root). The script configures the service to run under your user account.

**Option 1: Quick Run**

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Shubhamc4/setup-github-webhook/main/setup.sh)"
```

**Option 2: Download & Inspect**

```bash
curl -fsSL https://raw.githubusercontent.com/Shubhamc4/setup-github-webhook/main/setup.sh -o setup.sh
chmod +x setup.sh
bash setup.sh
```

### 2. Add the Deploy Key to GitLab

During execution, the script will pause and display a Public Key.
1. Copy the displayed key (starting with `ssh-ed25519`).
2. Go to your **GitLab Project > Settings > Repository**.
3. Expand Deploy Keys.
4. Click Add new key:
    - Title: `Webhook-Deploy-Server`
    - Key: Paste the public key here.
    - Grant write permissions: Leave unchecked (read-only is safer).
5. Click Add key.
6. Return to your terminal and press ENTER.

### 3. Follow the Prompts

The script will ask for:

| Prompt              | Description                                                   |
| ------------------- | ------------------------------------------------------------- |
| **Project Path**    | Absolute path to your project (e.g., `/var/www/html/my-app`). |
| **GitLab Repo URL** | The HTTPS URL of your repository.                             |
| **Branch**          | The branch to deploy (e.g., `main`).                          |
| **Discord Webhook** | (Optional) URL for deployment notifications.                  |

> **Note**: If you pre-define `PROJECT_PATH` env var, it may also prompt for the webhook base config path.

### 4. Setup GitLab Webhook

Once the script finishes, it will output valid **Webhook URL** and **Secret Token**.

1.  Go to your GitLab Project > Settings > Webhooks.
2.  **URL**: Paste the URL provided by the script.
3.  **Secret Token**: Paste the generated Secret Token.
4.  **Trigger**: Select "Push events".
5.  **SSL verification**: Enable if your server has HTTPS, otherwise disable.
6.  Click **Add webhook**.

## How It Works

1.  **Configuration**: Creates a config directory at `/var/www/deploy-webhook/<project-name>` containing:
    - `hooks.json`: The webhook definition.
    - `.git-askpass`: Helper script for git authentication using your token.
    - `redeploy.sh`: The actual deployment logic.
2.  **Service**: Registers a systemd service (`webhook.service`) listening on port **9000**.
3.  **Trigger**: When GitLab pushes code, the `webhook` tool verifies the secret and executes `redeploy.sh`.
4.  **Action**:
    - Fetches latest code from origin.
    - Compares local and remote hashes.
    - Running `git checkout` to update files.
    - Runs `npm install` (if `package.json` exists).
    - Runs `composer install` (if `composer.json` exists).
    - Sends Discord notification with status.

## Maintenance

**Check Deployment Status:**

```bash
sudo systemctl status webhook
```

**View Logs:**

```bash
tail -f /var/www/deploy-webhook/webhook.log
```

**Restart Service:**

```bash
sudo systemctl restart webhook
```

**Manual Trigger:**
You can run the deployment script manually to test:

```bash
/var/www/deploy-webhook/<project-name>/redeploy.sh
```

## 🔧 NGINX CONFIGURATION GUIDE

To expose the webhook securely, it is recommended to set up a reverse proxy with Nginx. This allows you to use a standard domain and SSL (HTTPS) for secure communication.

### 1. Nginx Server Block
Add or update your site configuration (e.g., `/etc/nginx/sites-available/default`):

```nginx
server {
  listen 80;
  server_name your-domain.com;

  location /webhooks/ {
    proxy_pass http://127.0.0.1:9000/;

    # Standard proxy headers
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # Optional: Limit access to specific IP ranges (e.g., GitLab IPs)
    # allow 140.82.112.0/20;
    # deny all;
  }
}
```

### 2. Apply Changes
Replace `your-domain.com` with your actual domain and set up SSL (e.g., using Let's Encrypt). After updating, reload Nginx:

`sudo nginx -t`
`sudo nginx -s reload`

---

## 🔐 SECURITY TIP: LIMITING WEBHOOK ACCESS

For enhanced security, restrict the webhook service so it only listens to requests coming from your local machine (Nginx). 

### Update Systemd Service
Edit the webhook systemd service to include an IP allow-list. Modify the `ExecStart` line in `/etc/systemd/system/webhook.service` to include the `-ip` flag:

`ExecStart=/usr/bin/webhook -hooks /var/www/deploy-webhook/hooks.json -hotreload -port 9000 -ip "127.0.0.1" -urlprefix ""`

### Restart Service
After making changes, reload the systemd daemon and restart the service:

`sudo systemctl daemon-reload`
`sudo systemctl restart webhook`

## Security

- **Firewall**: The script attempts to open port `9000` using `ufw`. Ensure your cloud provider firewall (AWS Security Groups, DigitalOcean, etc.) also allows traffic on port 9000.
- **Permissions**: The webhook service runs as the user who executed the setup script.
- **Secrets**: The GitLab token is stored in a file readable only by the owner `chmod 700`.

## Troubleshooting

- **Permission Denied (publickey)**: Ensure the Deploy Key was added to the specific GitLab repository and that you used the SSH URL (starts with git@), not HTTPS.
- **Permission Denied**: Ensure your user has write access to the `PROJECT_PATH`.
- **Webhook not triggering**: Check if port 9000 is open (`sudo ufw status`) and accessible from the internet.
- **Logs**: Check `/var/www/deploy-webhook/webhook.log` for execution errors.
