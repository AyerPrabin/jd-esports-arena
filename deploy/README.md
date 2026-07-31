# Deploying ZULU to an always-on VM

Moves `zulu_server.py` + the Discord bot off your PC onto a free, always-on Oracle Cloud VM,
with a real HTTPS URL (no more cloudflared tunnel / no more updating the URL every restart).
No local model is installed on the VM — the council runs entirely on the free-tier API keys
(Google Gemini, Groq) already in `zulu_secrets.py`, so any Always Free shape works.

## 0. Prerequisites — create the VM first (do this in the Oracle Cloud console, in a browser)
1. Sign up / log in at https://www.oracle.com/cloud/free/ (needs a card for identity
   verification, but the Always Free shapes below never get charged).
2. Console → **Compute → Instances → Create Instance**.
3. Name it (e.g. `zulu`), keep the default **Ubuntu 24.04** image.
4. Under "Shape", click Edit and pick an **Always Free** eligible shape:
   - `VM.Standard.E2.1.Micro` (1 OCPU / 1GB RAM, x86) — easiest to get, plenty for this
     Flask app since no model runs on the VM itself. Recommended.
   - `VM.Standard.A1.Flex` (Ampere/ARM, up to 4 OCPU/24GB) also works but is more often
     "out of capacity" — only bother if the Micro shape feels too small later.
5. Under "Add SSH keys", choose "Generate a key pair" and **download the private key file**
   (a `.key` file) — you only get it once.
6. Create the instance, then copy its **public IP** from the instance details page.
7. Instance details → attached **Virtual Cloud Network** → default **Security List** → Add
   Ingress Rules: allow TCP 80 and TCP 443 from `0.0.0.0/0` (the setup script also configures
   the VM's own firewall, but this network-level rule is separate and has to be opened here
   too, or the site will be unreachable from outside).

Once you have the VM's public IP and the downloaded `.key` file path, come back and tell me
— I'll run the rest of the deployment.

## 1. SSH in and run the bootstrap script
From your PC (PowerShell or Git Bash), replace `<VM_IP>` and the key filename:
```
scp -i your-key.key E:\ZULU\deploy\setup_vm.sh ubuntu@<VM_IP>:~/
ssh -i your-key.key ubuntu@<VM_IP>
chmod +x setup_vm.sh && ./setup_vm.sh
```
This installs Python and Caddy (automatic HTTPS via a `nip.io` hostname derived from the
VM's own IP — e.g. IP `140.238.1.2` becomes `https://140-238-1-2.nip.io`, zero DNS setup
needed). It prints your HTTPS URL at the end — save it.

## 2. Copy the app code + secrets over
Only these files are actually needed (not the whole repo — no images/gameplay videos/the
static site itself, those stay on GitHub Pages):
```
scp -i your-key.key E:\ZULU\zulu_server.py E:\ZULU\zulu_discord.py E:\ZULU\zulu_knowledge.py ^
    E:\ZULU\zulu_private.py E:\ZULU\zulu_parts.py E:\ZULU\zulu_graph.py E:\ZULU\zulu_secrets.py ^
    E:\ZULU\tournaments.json ubuntu@<VM_IP>:~/zulu/
```
(`^` is PowerShell's line-continuation — on Git Bash use `\` instead.)

**On the VM**, edit `~/zulu/zulu_secrets.py` and set `OLLAMA_MODEL = ""` (leave your PC's
copy alone if you still want Ollama available there for other things) — the VM's council
runs on `GOOGLE_API_KEY`/`GROQ_API_KEY` alone, no local model needed.

**Before you do that, get an `OPENROUTER_API_KEY`** (free, no card, openrouter.ai/keys) if you
haven't already — dropping Ollama takes the council from 3 model families down to 2 (Groq's
llama + Google's gemini), which is council_vote()'s bare minimum floor: one provider hiccup
and a vote goes inconclusive. OpenRouter is wired to `openai/gpt-oss-20b:free`, a genuinely
different family from both, so this restores real quorum headroom instead of just replacing
what Ollama was doing. It's also a hard requirement for `AUTO_EXECUTE_APPROVE_PAYMENT` (see
zulu_secrets.py) to ever fire — that flag needs 3 independent families to agree unanimously,
and stays permanently inert without this key.

## 3. Install the systemd services
```
scp -i your-key.key E:\ZULU\deploy\zulu-server.service E:\ZULU\deploy\zulu-discord.service ubuntu@<VM_IP>:~/
ssh -i your-key.key ubuntu@<VM_IP>
sudo mv ~/zulu-server.service ~/zulu-discord.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now zulu-server zulu-discord
```
`Restart=always` is baked into both unit files — systemd relaunches either process if it
crashes, and both start automatically on every VM reboot (no more Windows Startup-folder
shortcuts needed). Check they're actually running:
```
sudo systemctl status zulu-server
sudo systemctl status zulu-discord
curl https://<your-nip.io-url>/health
```

## 4. Point everything at the new URL
Replace the old cloudflared tunnel URL in each of these with your new `https://...nip.io`
URL (or a real domain later):
- `E:\ZULU\index.html` — the `ZULU_PUBLIC_URL` constant
- `E:\prabin-ayer-portfolio\assets\js\chat-widget.js` — the `PORTFOLIO_AI_URL` constant
- `E:\jd-stock\.env.local` (and the same var in Vercel's project settings) — `ZULU_SERVER_URL`

Once these are updated and republished, none of them depend on your PC being on anymore.

## Updating the code later
Whenever you change `zulu_server.py`/`zulu_discord.py` locally, re-run the `scp` command from
step 2 for just the changed files, then:
```
ssh -i your-key.key ubuntu@<VM_IP> "sudo systemctl restart zulu-server zulu-discord"
```

## Logs
```
tail -f ~/zulu/zulu-server.log
tail -f ~/zulu/zulu-discord.log
```
