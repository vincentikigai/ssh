#!/usr/bin bash

# 1. Detect OneDrive path based on OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS typical CloudStorage path
    ONEDRIVE_SSH="$HOME/OneDrive/ssh"
else
    # Linux (adjust if you mount rclone/onedriver elsewhere)
    ONEDRIVE_SSH="$HOME/OneDrive/ssh"
fi

echo "Setting up SSH config from: $ONEDRIVE_SSH"

# 2. Ensure local .ssh exists
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# 3. Create the local override file if it doesn't exist
touch "$HOME/.ssh/config_local"
chmod 600 "$HOME/.ssh/config_local"

# 4. Backup existing config if it exists, then link
if [ -e "$HOME/.ssh/config" ] || [ -L "$HOME/.ssh/config" ]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_NAME="$HOME/.ssh/config.bak_$TIMESTAMP"
    echo "⚠️ Existing config found. Backing up to: $BACKUP_NAME"
    mv "$HOME/.ssh/config" "$BACKUP_NAME"
fi

ln -s "$ONEDRIVE_SSH/config" "$HOME/.ssh/config"

echo "✅ Symlink created. Locking down permissions..."
chmod 600 "$ONEDRIVE_SSH/config"

echo "🎉 Done! Test it by running: ssh -G any-host"
