#!/bin/sh
set -eu

# BH860 Manager v2
# ZTE B860H OpenWrt + Huawei E5372 HiLink
# Modem reboot is performed through authenticated HiLink API.
# No USB authorized reset is used.

CFG=/etc/config/bh860manager
BASE=/etc/bh860manager
CTL=/usr/sbin/bh860managerctl
WATCHDOG=/usr/sbin/bh860manager-watchdog
INIT=/etc/init.d/bh860manager
CTRL=/usr/lib/lua/luci/controller/bh860manager.lua
MODEL=/usr/lib/lua/luci/model/cbi/bh860manager.lua
VIEW=/usr/lib/lua/luci/view/bh860manager.htm
ACL=/usr/share/rpcd/acl.d/luci-app-bh860manager.json

log(){ echo "[BH860] $*"; }

log "Memasang BH860 Manager v2..."
mkdir -p "$BASE" /usr/lib/lua/luci/controller /usr/lib/lua/luci/model/cbi /usr/lib/lua/luci/view /usr/share/rpcd/acl.d

if ! command -v curl >/dev/null 2>&1; then
    log "Memasang curl..."
    opkg update >/dev/null 2>&1 || true
    opkg install curl >/dev/null 2>&1 || { log "GAGAL memasang curl"; exit 1; }
fi

cat > "$CFG" <<'EOC'
config settings 'main'
    option enabled '1'
    option check_interval '60'
    option fail_limit '5'
    option target '1.1.1.1'
    option recovery_wait '2'
    option cooldown '600'
    option modem_enabled '1'
    option modem_ip '192.168.8.1'
    option modem_username 'admin'
    option modem_password ''
EOC
chmod 600 "$CFG"

cat > "$CTL" <<'EOC'
#!/bin/sh
set -u

CFG=/etc/config/bh860manager
TMP=/tmp/bh860manager
COOKIE=$TMP/cookie
HDR=$TMP/header
HOME=$TMP/home.html
mkdir -p "$TMP"
chmod 700 "$TMP"

cfg(){ uci -q get "bh860manager.main.$1" 2>/dev/null || true; }
MODEM_IP="$(cfg modem_ip)"; [ -n "$MODEM_IP" ] || MODEM_IP=192.168.8.1
USER="$(cfg modem_username)"; [ -n "$USER" ] || USER=admin
PASS="$(cfg modem_password)"

xml(){ printf '%s' "$1" | sed -n "s:.*<$2>\([^<]*\)</$2>.*:\\1:p" | head -n1; }
sha(){ printf '%s' "$1" | sha256sum | awk '{print $1}'; }
b64(){ printf '%s' "$1" | base64 2>/dev/null | tr -d '\r\n'; }

fetch_home(){
    rm -f "$COOKIE" "$HOME"
    curl -sS --max-time 8 -c "$COOKIE" "http://$MODEM_IP/html/home.html" -o "$HOME" || return 1
    [ -s "$HOME" ] || return 1
}

get_sestok(){
    R="$(curl -sS --max-time 8 -b "$COOKIE" -c "$COOKIE" "http://$MODEM_IP/api/webserver/SesTokInfo" 2>/dev/null || true)"
    SES="$(xml "$R" SesInfo)"
    TOK="$(xml "$R" TokInfo)"
    [ -n "$SES" ] || return 1
    [ -n "$TOK" ] || return 1
    case "$SES" in SessionID=*) SID=${SES#SessionID=};; *) SID=$SES;; esac
    printf '#HttpOnly_192.168.8.1\tFALSE\t/\tFALSE\t0\tSessionID\t%s\n' "$SID" > "$COOKIE"
    chmod 600 "$COOKIE"
    TOKEN="$TOK"
    return 0
}

home_token(){
    # E5372 firmware seen in this device exposes csrf_token as a meta tag.
    sed -n 's/.*name="csrf_token"[^>]*content="\([^"]*\)".*/\1/p' "$HOME" | head -n1
}

header_token(){
    grep -i '^__RequestVerificationToken:' "$HDR" 2>/dev/null | head -n1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'
}

state(){ curl -sS --max-time 8 -b "$COOKIE" -H 'X-Requested-With: XMLHttpRequest' "http://$MODEM_IP/api/user/state-login" 2>/dev/null || true; }

login(){
    [ -n "$PASS" ] || { echo 'ERROR: password modem belum diisi di LuCI.'; return 1; }
    fetch_home || { echo 'ERROR: /html/home.html tidak bisa diakses.'; return 1; }
    get_sestok || { echo 'ERROR: SesTokInfo gagal.'; return 1; }

    S="$(state)"
    if printf '%s' "$S" | grep -q '<State>0</State>'; then
        echo 'OK: modem sudah login.'
        return 0
    fi

    # Firmware E5372 can expose the login CSRF token in home.html.
    HT="$(home_token)"
    [ -n "$HT" ] || HT="$TOKEN"

    # Huawei WebUI password_type=4: SHA256(password) -> Base64,
    # then SHA256(username + Base64(password_sha256) + token) -> Base64.
    PH="$(sha "$PASS")"
    PHB="$(b64 "$PH")"
    FINAL="$(sha "${USER}${PHB}${HT}")"
    FINALB="$(b64 "$FINAL")"
    XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Username>${USER}</Username><Password>${FINALB}</Password><password_type>4</password_type></request>"

    rm -f "$HDR"
    R="$(curl -sS --max-time 8 -D "$HDR" -b "$COOKIE" -c "$COOKIE" \
      -H 'Content-Type: text/xml' \
      -H 'X-Requested-With: XMLHttpRequest' \
      -H "__RequestVerificationToken: $HT" \
      -X POST --data "$XML" "http://$MODEM_IP/api/user/login" 2>/dev/null || true)"

    if printf '%s' "$R" | grep -q '<response>OK</response>'; then
        NEW="$(header_token)"
        [ -n "$NEW" ] && TOKEN="$NEW"
        echo 'OK: login Huawei berhasil.'
        return 0
    fi

    # Some firmware uses the SesTokInfo token instead of home.html token.
    if [ "$HT" != "$TOKEN" ]; then
        rm -f "$HDR"
        R="$(curl -sS --max-time 8 -D "$HDR" -b "$COOKIE" -c "$COOKIE" \
          -H 'Content-Type: text/xml' \
          -H 'X-Requested-With: XMLHttpRequest' \
          -H "__RequestVerificationToken: $TOKEN" \
          -X POST --data "$XML" "http://$MODEM_IP/api/user/login" 2>/dev/null || true)"
        if printf '%s' "$R" | grep -q '<response>OK</response>'; then
            NEW="$(header_token)"; [ -n "$NEW" ] && TOKEN="$NEW"
            echo 'OK: login Huawei berhasil.'
            return 0
        fi
    fi

    echo 'ERROR: login Huawei gagal.'
    printf '%s\n' "$R"
    return 1
}

reboot_modem(){
    login || return 1
    XML='<request><Control>1</Control></request>'
    R="$(curl -sS --max-time 8 -b "$COOKIE" -c "$COOKIE" \
      -H 'Content-Type: text/xml' \
      -H 'X-Requested-With: XMLHttpRequest' \
      -H "__RequestVerificationToken: $TOKEN" \
      -X POST --data "$XML" "http://$MODEM_IP/api/device/control" 2>/dev/null || true)"
    if printf '%s' "$R" | grep -q '<response>OK</response>'; then
        echo 'OK: perintah reboot Huawei diterima.'
        return 0
    fi
    echo 'ERROR: reboot Huawei gagal:'
    printf '%s\n' "$R"
    return 1
}

test(){
    echo "Huawei E5372: $MODEM_IP"
    if ! ping -c 1 -W 2 "$MODEM_IP" >/dev/null 2>&1; then echo 'ERROR: modem tidak terjangkau.'; return 1; fi
    login
}

both(){
    if reboot_modem; then
        echo 'Tunggu 2 detik...'
        sleep 2
        sync
        reboot
    else
        echo 'OpenWrt TIDAK direboot karena reboot modem gagal.'
        return 1
    fi
}

case "${1:-}" in
  test|modem-test|login|modem-login) test ;;
  modem) reboot_modem ;;
  both) both ;;
  *) echo 'Gunakan: test | modem | both'; exit 1 ;;
esac
EOC
chmod 700 "$CTL"

cat > "$WATCHDOG" <<'EOC'
#!/bin/sh
set -u
TAG=bh860-manager
get(){ uci -q get "bh860manager.main.$1" 2>/dev/null || true; }
EN="$(get enabled)"; [ "$EN" = 1 ] || exit 0
INTERVAL="$(get check_interval)"; [ -n "$INTERVAL" ] || INTERVAL=60
LIMIT="$(get fail_limit)"; [ -n "$LIMIT" ] || LIMIT=5
TARGET="$(get target)"; [ -n "$TARGET" ] || TARGET=1.1.1.1
WAIT="$(get recovery_wait)"; [ -n "$WAIT" ] || WAIT=2
MODEM="$(get modem_enabled)"; [ -n "$MODEM" ] || MODEM=1
FAIL=0
logger -t "$TAG" "Started target=$TARGET interval=${INTERVAL}s fail_limit=$LIMIT modem=$(get modem_ip)"
while :; do
  if ping -c 1 -W 3 "$TARGET" >/dev/null 2>&1; then
    FAIL=0
  else
    FAIL=$((FAIL+1)); logger -t "$TAG" "Ping gagal $FAIL/$LIMIT"
    if [ "$FAIL" -ge "$LIMIT" ]; then
      FAIL=0
      if [ "$MODEM" = 1 ]; then
        logger -t "$TAG" "Internet gagal $LIMIT kali -> login/reboot Huawei"
        "$CTL" modem || logger -t "$TAG" 'Reboot Huawei gagal'
      fi
      sleep "$WAIT"
      logger -t "$TAG" 'Reboot OpenWrt'
      sync
      reboot
      exit 0
    fi
  fi
  sleep "$INTERVAL"
done
EOC
chmod 700 "$WATCHDOG"

cat > "$INIT" <<'EOC'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service(){
  [ "$(uci -q get bh860manager.main.enabled)" = 1 ] || return 0
  procd_open_instance
  procd_set_param command /usr/sbin/bh860manager-watchdog
  procd_set_param respawn 3600 5 0
  procd_close_instance
}
EOC
chmod 755 "$INIT"

cat > "$CTRL" <<'EOC'
module("luci.controller.bh860manager", package.seeall)
function index()
  if not nixio.fs.access("/etc/config/bh860manager") then return end
  entry({"admin","services","bh860manager"}, template("bh860manager"), _("Manajer Restart Otomatis BH860"), 80).dependent=false
end
EOC

cat > "$VIEW" <<'EOC'
<%+header%>
<h2>Manajer Restart Otomatis BH860</h2>

<% if luci.http.formvalue("save") then
  local uci = require("luci.model.uci").cursor()
  local keys = {"enabled","check_interval","fail_limit","target","recovery_wait","cooldown","modem_enabled","modem_ip","modem_username","modem_password"}
  for _,k in ipairs(keys) do
    local v = luci.http.formvalue(k)
    if v ~= nil then uci:set("bh860manager","main",k,v) end
  end
  uci:commit("bh860manager")
  os.execute("/etc/init.d/bh860manager restart >/dev/null 2>&1")
%><div class="alert-message success">Pengaturan berhasil disimpan.</div><% end %>

<% if luci.http.formvalue("action") == "test" then
  local r = luci.sys.exec("/usr/sbin/bh860managerctl test 2>&1")
%><div class="alert-message"><pre><%=r%></pre></div><% elseif luci.http.formvalue("action") == "modem" then
  local r = luci.sys.exec("/usr/sbin/bh860managerctl modem 2>&1")
%><div class="alert-message"><pre><%=r%></pre></div><% end %>

<form method="post">
<div class="cbi-map">
<div class="cbi-section">
<h3>Huawei E5372</h3>
<table class="cbi-section-table">
<tr><td width="30%">Aktifkan reboot modem</td><td><input type="checkbox" name="modem_enabled" value="1" <% if uci:get("bh860manager","main","modem_enabled")=="1" then %>checked<% end %>></td></tr>
<tr><td>IP Modem</td><td><input class="cbi-input-text" name="modem_ip" value="<%=uci:get("bh860manager","main","modem_ip") or "192.168.8.1"%>"></td></tr>
<tr><td>Username</td><td><input class="cbi-input-text" name="modem_username" value="<%=uci:get("bh860manager","main","modem_username") or "admin"%>"></td></tr>
<tr><td>Password</td><td><input class="cbi-input-text" type="password" name="modem_password" value="<%=uci:get("bh860manager","main","modem_password") or ""%>" autocomplete="new-password"></td></tr>
</table>
</div>

<div class="cbi-section">
<h3>Watchdog Internet</h3>
<table class="cbi-section-table">
<tr><td width="30%">Aktifkan watchdog</td><td><input type="checkbox" name="enabled" value="1" <% if uci:get("bh860manager","main","enabled")=="1" then %>checked<% end %>></td></tr>
<tr><td>Interval cek (detik)</td><td><input class="cbi-input-text" name="check_interval" value="<%=uci:get("bh860manager","main","check_interval") or "60"%>"></td></tr>
<tr><td>Batas gagal</td><td><input class="cbi-input-text" name="fail_limit" value="<%=uci:get("bh860manager","main","fail_limit") or "5"%>"></td></tr>
<tr><td>Ping target</td><td><input class="cbi-input-text" name="target" value="<%=uci:get("bh860manager","main","target") or "1.1.1.1"%>"></td></tr>
<tr><td>Tunggu sebelum OpenWrt restart</td><td><input class="cbi-input-text" name="recovery_wait" value="<%=uci:get("bh860manager","main","recovery_wait") or "2"%>"> detik</td></tr>
<tr><td>Cooldown</td><td><input class="cbi-input-text" name="cooldown" value="<%=uci:get("bh860manager","main","cooldown") or "600"%>"> detik</td></tr>
</table>
</div>

<div class="cbi-section">
<h3>Aksi Manual</h3>
<button class="cbi-button cbi-button-apply" name="save" value="1" type="submit">Simpan Pengaturan</button>
<button class="cbi-button cbi-button-apply" name="action" value="test" type="submit">Tes Login Modem</button>
<button class="cbi-button cbi-button-reset" name="action" value="modem" type="submit" onclick="return confirm('Restart Huawei E5372 sekarang?')">Restart Modem</button>
</div>
</div>
</form>

<div class="cbi-section">
<h3>Alur otomatis</h3>
<p>Internet gagal <b>5 kali</b> → login Huawei → reboot E5372 → tunggu <b>2 detik</b> → reboot OpenWrt.</p>
<p><b>Catatan:</b> watchdog tidak menggunakan USB authorized reset.</p>
</div>
<%+footer%>
EOC

# The view uses a UCI cursor named 'uci'. Inject it before rendering.
python3 - <<'PY' 2>/dev/null || true
from pathlib import Path
p=Path('/usr/lib/lua/luci/view/bh860manager.htm')
s=p.read_text()
s=s.replace('<h2>Manajer Restart Otomatis BH860</h2>', '<% local uci = require("luci.model.uci").cursor() %>\n<h2>Manajer Restart Otomatis BH860</h2>', 1)
p.write_text(s)
PY

# Do the same with sed fallback if python3 is unavailable on OpenWrt.
if ! grep -q 'local uci = require' "$VIEW"; then
  sed -i '1a <% local uci = require("luci.model.uci").cursor() %>' "$VIEW"
fi

cat > "$ACL" <<'EOC'
{
  "luci-app-bh860manager": {
    "description": "BH860 Manager",
    "read": { "ubus": {} },
    "write": {}
  }
}
EOC

chmod 600 "$CFG"
/etc/init.d/bh860manager enable
/etc/init.d/bh860manager restart || /etc/init.d/bh860manager start
rm -f /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true

log "INSTALASI SELESAI"
echo
echo "Buka: Services -> Manajer Restart Otomatis BH860"
echo
echo "Semua akun modem dan pengaturan sekarang di LuCI."
echo "Tidak perlu set-credentials lewat terminal."
echo
echo "Setelah isi username/password di LuCI:"
echo "  1. Simpan Pengaturan"
echo "  2. Tes Login Modem"
echo "  3. Jika OK, gunakan Restart Modem"
echo
echo "Watchdog: 60 detik / 5 gagal -> Huawei reboot -> 2 detik -> OpenWrt reboot"
echo
