#!/bin/bash

# --- Identify the User ---
# Captures the name of the user who is running the script
if [ "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER=$(whoami)
fi

# Define paths based on the collected user
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
CLIENT_OVPN="$USER_HOME/client.ovpn"
SERVER_CONF="/etc/openvpn/server/server.conf"
PAM_CONF="/etc/pam.d/openvpn"
TFA_DIR="/etc/openvpn/2fa"
PORT="443"
PROTO="tcp"

# Ensure script is run as root for system-level changes
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)"
   exit 1
fi

echo "--- 1. Installing OpenVPN (User: $REAL_USER) ---"
# Downloads the installer script from the source
if [ ! -f "openvpn-install.sh" ]; then
    wget https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
    chmod +x openvpn-install.sh
fi
# Executes the OpenVPN installation
sudo ./openvpn-install.sh

echo "--- 2. Installing & Configuring 2FA ---"
# Installs the Google Authenticator PAM module
sudo apt update && sudo apt install -y libpam-google-authenticator

# Configures PAM for OpenVPN using the dynamic user secret path
sudo bash -c "cat > $PAM_CONF" <<EOF
# Standard password check (optional)
# @include common-auth
# @include common-account

# Google Authenticator requirement
auth required pam_google_authenticator.so secret=$TFA_DIR/\${USER} user=root
EOF

echo "--- 3. Updating Server Configuration ---"
# Updates server port and protocol to TCP 443
sed -i "s/^port .*/port $PORT/" "$SERVER_CONF"
sed -i "s/^proto .*/proto $PROTO/" "$SERVER_CONF"

# Adds the PAM plugin and challenge prompt to the server config
if ! grep -q "openvpn-plugin-auth-pam.so" "$SERVER_CONF"; then
    sudo bash -c "cat >> $SERVER_CONF" <<EOF

# Enable PAM for 2FA
plugin /usr/lib/x86_64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so openvpn
static-challenge "Enter Google Auth Code: " 1
EOF
fi

echo "--- 4. Updating Client Configuration ---"
# Modifies the client.ovpn file located in the user's home directory
if [ -f "$CLIENT_OVPN" ]; then
    # Sets client protocol to TCP
    sed -i "s/^proto .*/proto $PROTO/" "$CLIENT_OVPN"
    # Adds auth-user-pass to enable 2FA prompt
    if ! grep -q "auth-user-pass" "$CLIENT_OVPN"; then
        echo "auth-user-pass" >> "$CLIENT_OVPN"
    fi
    echo "Client file updated at $CLIENT_OVPN"
else
    echo "Warning: Client file not found at $CLIENT_OVPN"
fi

echo "--- 5. Finalizing 2FA Directory & Restart ---"
# Creates the secret storage directory with restricted permissions
sudo mkdir -p $TFA_DIR
sudo chown root:root $TFA_DIR
sudo chmod 700 $TFA_DIR

# Restarts the OpenVPN service to apply all changes
sudo systemctl restart openvpn-server@server

echo "--- SETUP COMPLETE ---"
echo "1. Run 'google-authenticator' as $REAL_USER."
echo "2. Move the file: sudo mv $USER_HOME/.google_authenticator $TFA_DIR/$REAL_USER"
echo "3. Permissions: sudo chown nobody:nogroup $TFA_DIR/$REAL_USER && sudo chmod 400 $TFA_DIR/$REAL_USER"
