#!/bin/bash
trap "echo [supervisor] Caught exit signal; exit 0" SIGTERM SIGINT

export PATH="/home/codespace/.nvm/current/bin:/home/codespace/nvm/current/bin:/home/codespace/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
[ -s "/usr/local/share/nvm/nvm.sh" ] && \. "/usr/local/share/nvm/nvm.sh"
[ -s "/home/codespace/.nvm/nvm.sh" ] && \. "/home/codespace/.nvm/nvm.sh"

TOKEN="eyJhIjoiOWI0N2Q0ZTYwNjQ4MjEzMGMyODU0MzNhM2I2NzM3ZjgiLCJ0IjoiNzEyZWMyNTItM2YwNC00NDdiLWFjMDctYzNhYmIxMGQzMWViIiwicyI6ImNrMWJJR3MzSW93dUpVbFBLYWg0bWZRdW9TaXVXczdLWE1PaEhnb0MySVU9In0="

check_and_heal() {
    # 1. Ensure ports are public
    if [ -n "$CODESPACE_NAME" ]; then
        gh codespace ports visibility 4096:public 7681:public 6767:public -c "$CODESPACE_NAME" 2>/dev/null || true
    fi

    # 2. /etc/hosts resolution
    if ! grep -q "4096" /etc/hosts 2>/dev/null; then
        echo "127.0.0.1 4096" | tee -a /etc/hosts > /dev/null
    fi

    # 3. Port 80 Bridge -> 4096
    if ! pgrep -f "port80_bridge.mjs" > /dev/null 2>&1; then
        fuser -k 80/tcp > /dev/null 2>&1 || true
        [ -f /usr/local/bin/port80_bridge.mjs ] && nohup node /usr/local/bin/port80_bridge.mjs </dev/null > /tmp/port80_bridge.log 2>&1 &
    fi

    # 4. OpenCode Web UI (Port 4096)
    if ! pgrep -f "opencode web" > /dev/null 2>&1; then
        OPENCODE_BIN="/home/codespace/.nvm/current/bin/opencode"
        [ ! -x "$OPENCODE_BIN" ] && OPENCODE_BIN="/home/codespace/nvm/current/bin/opencode"
        [ ! -x "$OPENCODE_BIN" ] && OPENCODE_BIN="opencode"
        su - codespace -c "nohup $OPENCODE_BIN web --port 4096 --hostname 0.0.0.0 </dev/null > /tmp/opencode.log 2>&1 &" || true
    fi

    # 5. ttyd Web Terminal (Port 7681)
    if ! pgrep -f "ttyd.*7681" > /dev/null 2>&1; then
        TTYD_BIN="/home/codespace/.local/bin/ttyd"
        [ ! -x "$TTYD_BIN" ] && TTYD_BIN="ttyd"
        su - codespace -c "nohup $TTYD_BIN --writable -p 7681 --interface 0.0.0.0 bash </dev/null > /tmp/ttyd.log 2>&1 &" || true
    fi

    # 6. Paseo Daemon (Port 6767)
    if ! pgrep -f "paseo daemon" > /dev/null 2>&1; then
        su - codespace -c "export PASEO_WEB_UI_ENABLED=true; nohup paseo daemon start --web-ui --listen 0.0.0.0:6767 </dev/null > /tmp/paseo.log 2>&1 &" || true
    fi

    # 7. Cloudflare Persistent Named Tunnel (codespace2)
    if ! pgrep -f "cloudflared tunnel run" > /dev/null 2>&1; then
        nohup /usr/local/bin/cloudflared tunnel run --token "$TOKEN" </dev/null > /tmp/cf_named_tunnel.log 2>&1 &
    fi
}

if [ "$1" = "--check-once" ]; then
    check_and_heal
    exit 0
fi

DAEMON_PIDFILE="/tmp/codespace-supervisor.pid"
if [ -f "$DAEMON_PIDFILE" ]; then
    OLD_PID=$(cat "$DAEMON_PIDFILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$DAEMON_PIDFILE"

echo "[$(date -u)] codespace-supervisor daemon active on Codespace 2 (pid: $$)."
while true; do
    check_and_heal
    sleep 8
done
