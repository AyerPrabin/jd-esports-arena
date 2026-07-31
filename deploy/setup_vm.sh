#!/bin/bash
# Bootstrap script for a fresh Oracle Cloud "Always Free" Ubuntu 24.04 VM.
# Run this ON THE VM (after SSH-ing in), not on your own PC:
#   scp -i your-key.key deploy/setup_vm.sh ubuntu@<VM_IP>:~/
#   ssh -i your-key.key ubuntu@<VM_IP>
#   chmod +x setup_vm.sh && ./setup_vm.sh
#
# Installs Python only -- NOT Ollama. The council already has working free-tier API keys
# (Google Gemini, Groq) in zulu_secrets.py, so no local model is needed on the VM. This
# means any Always Free shape works, including the small always-available
# VM.Standard.E2.1.Micro (1 OCPU/1GB RAM, x86) -- you don't need to fight Oracle's capacity
# limits on the bigger Ampere (ARM) shape just to get a VM provisioned.
#
# Also installs Caddy as a reverse proxy in front of zulu_server.py, with AUTOMATIC HTTPS --
# this matters because index.html/the portfolio/jd-stock are all served over HTTPS, and
# browsers block an HTTPS page from calling a plain HTTP backend (mixed content). Caddy gets
# a free Let's Encrypt cert for a nip.io hostname derived from this VM's own IP, so this
# works with zero DNS setup -- swap in a real domain later if you want a nicer URL.
#
# Does NOT copy zulu_secrets.py or the app code itself -- those get transferred separately
# (see deploy/README.md) since zulu_secrets.py holds real API keys and should never touch
# a script or a git history.
set -e

echo "=== Detecting this VM's public IP ==="
VM_IP=$(curl -s ifconfig.me)
NIP_HOST=$(echo "$VM_IP" | tr '.' '-').nip.io
echo "Public IP: $VM_IP"
echo "Your HTTPS URL will be: https://$NIP_HOST"

echo "=== Updating system ==="
sudo apt-get update -y
sudo apt-get install -y python3 python3-pip python3-venv git curl debian-keyring debian-archive-keyring apt-transport-https iptables-persistent

echo "=== Installing Caddy (reverse proxy + automatic HTTPS) ==="
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
sudo chmod o+r /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update -y
sudo apt-get install -y caddy

echo "=== Writing Caddyfile (proxies https://$NIP_HOST -> localhost:5005) ==="
sudo tee /etc/caddy/Caddyfile > /dev/null <<EOF
$NIP_HOST {
    reverse_proxy localhost:5005
}
EOF
sudo systemctl restart caddy

echo "=== Opening firewall: 80+443 (Caddy/HTTPS), NOT 5005 (stays localhost-only behind Caddy) ==="
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save

echo "=== Creating app directory ==="
mkdir -p ~/zulu/venv

echo "=== Setting up Python virtual environment ==="
python3 -m venv ~/zulu/venv
source ~/zulu/venv/bin/activate
pip install --upgrade pip
# flask/flask-cors/requests: zulu_server.py itself. discord.py: zulu_discord.py (separate
# process, same venv). networkx: zulu_graph.py's /graph/* routes (imported unconditionally by
# zulu_server.py, wrapped in try/except so its absence wouldn't crash the server -- but then
# /graph/* just wouldn't work, so install it). Deliberately NOT installing: numpy (nothing in
# this codebase imports it), openpyxl/pdfplumber (only used by ingest_parts_catalog.py, a
# local one-shot script that isn't copied to this VM), psutil/Pillow (only power laptop-control
# tool functions -- LAPTOP_CONTROL defaults off, and "screenshot"/"lock the workstation" would
# act on this headless VM, not your actual laptop, if ever turned on here).
pip install flask flask-cors requests discord.py networkx

# Optional: only needed if you turn on video-evidence analysis for cheating reports
# (zulu_secrets.py has no separate on/off flag for it -- it's just inert without ffmpeg on
# PATH, see the note next to SPONSOR_CANDIDATES there). Not installed by default since it's a
# real system package, not a pip one, and most deployments won't use this feature immediately.
#   sudo apt install -y ffmpeg

echo ""
echo "================================================================"
echo "Done. Your public HTTPS URL (once zulu_server.py is running):"
echo "  https://$NIP_HOST"
echo "================================================================"
echo "Next steps (see deploy/README.md):"
echo "1. Copy the app code + zulu_secrets.py into ~/zulu/ (scp from your PC)"
echo "2. On the VM's zulu_secrets.py: leave OLLAMA_MODEL blank -- the council uses your free API keys instead"
echo "3. Install the systemd services (deploy/zulu-server.service, deploy/zulu-discord.service)"
echo "4. sudo systemctl enable --now zulu-server zulu-discord"
echo "5. Update index.html/portfolio/jd-stock to point at https://$NIP_HOST instead of the old cloudflared URL"
