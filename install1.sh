#!/bin/sh
set -eu
BASE=/etc/bh860manager
CFG=/etc/config/bh860manager
INIT=/etc/init.d/bh860manager
WATCHDOG=/usr/sbin/bh860manager-watchdog
CTL=/usr/sbin/bh860managerctl
LUCI_CTRL=/usr/lib/lua/luci/controller/bh860manager.lua
LUCI_MODEL=/usr/lib/lua/luci/model/cbi/bh860manager.lua
LUCI_VIEW=/usr/lib/lua/luci/view/bh860manager.htm
ACL=/usr/share/rpcd/acl.d/luci-app-bh860manager.json

echo '[BH860] Memasang BH860 Manager...'
mkdir -p "$BASE" "$(dirname "$LUCI_MODEL")" "$(dirname "$LUCI_VIEW")" "$(dirname "$ACL")"
command -v curl >/dev/null 2>&1 || { opkg update >/dev/null 2>&1 || true; opkg install curl >/dev/null 2>&1 || { echo '[BH860] GAGAL memasang curl'; exit 1; }; }
cat > "$CFG" <<'EOC'
config settings 'main'
    option enabled '1'
    option check_interval '60'
    option fail_limit '5'
    option target '1.1.1.1'
    option recovery_wait '2'
    option cooldown '600'
    option modem_ip '192.168.8.1'
    option modem_enabled '1'
    option modem_username 'admin'
    option modem_password ''
EOC
chmod 600 "$CFG"
cat > "$CTL" <<'EOC'
#!/bin/sh
set -u
CFG=/etc/config/bh860manager
MODEM_IP="$(uci -q get bh860manager.main.modem_ip || echo 192.168.8.1)"
MODEM_USER="$(uci -q get bh860manager.main.modem_username || echo admin)"
MODEM_PASS="$(uci -q get bh860manager.main.modem_password || echo '')"
TMP=/tmp/bh860manager
COOKIE="$TMP/cookie"
LOGIN_HDR="$TMP/login_header"
mkdir -p "$TMP"; chmod 700 "$TMP"
xml_get(){ echo "$1" | sed -n "s:.*<$2>\([^<]*\)</$2>.*:\1:p" | head -n1; }
b64(){ printf '%s' "$1" | base64 2>/dev/null | tr -d '\r\n'; }
sha256_hex(){ printf '%s' "$1" | sha256sum | awk '{print $1}'; }
get_session_token(){
  rm -f "$COOKIE"
  RESP="$(curl -sS --max-time 8 -c "$COOKIE" "http://$MODEM_IP/api/webserver/SesTokInfo" 2>/dev/null || true)"
  SES="$(xml_get "$RESP" SesInfo)"; TOKEN="$(xml_get "$RESP" TokInfo)"
  [ -n "$SES" ] && [ -n "$TOKEN" ] || return 1
  case "$SES" in SessionID=*) SID="${SES#SessionID=}";; *) SID="$SES";; esac
  printf '# Netscape HTTP Cookie File\n#HttpOnly_192.168.8.1\tFALSE\t/\tFALSE\t0\tSessionID\t%s\n' "$SID" > "$COOKIE"
  chmod 600 "$COOKIE"
}
new_token(){
  NEW="$(grep -i '^__RequestVerificationToken:' "$LOGIN_HDR" 2>/dev/null | head -n1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"
  [ -n "$NEW" ] && { TOKEN="$NEW"; return 0; }; return 1
}
state_login(){ curl -sS --max-time 8 -b "$COOKIE" -H 'X-Requested-With: XMLHttpRequest' "http://$MODEM_IP/api/user/state-login" 2>/dev/null || true; }
login_modem(){
  [ -n "$MODEM_PASS" ] || { echo 'ERROR: password modem belum diset'; echo 'Jalankan: bh860managerctl set-credentials'; return 1; }
  get_session_token || { echo 'ERROR: gagal mendapatkan SessionID/Token Huawei'; return 1; }
  STATE="$(state_login)"; echo "$STATE" | grep -q '<State>0</State>' && return 0
  PWHEX="$(sha256_hex "$MODEM_PASS")"; PWB64="$(b64 "$PWHEX")"; FINALHEX="$(sha256_hex "${MODEM_USER}${PWB64}${TOKEN}")"; FINALB64="$(b64 "$FINALHEX")"
  XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Username>${MODEM_USER}</Username><Password>${FINALB64}</Password><password_type>4</password_type></request>"
  rm -f "$LOGIN_HDR"
  RESP="$(curl -sS --max-time 8 -D "$LOGIN_HDR" -b "$COOKIE" -c "$COOKIE" -H 'Content-Type: text/xml' -H 'X-Requested-With: XMLHttpRequest' -H "__RequestVerificationToken: $TOKEN" -X POST --data "$XML" "http://$MODEM_IP/api/user/login" 2>/dev/null || true)"
  if echo "$RESP" | grep -q '<response>OK</response>'; then new_token || get_session_token || true; return 0; fi
  echo 'ERROR: login Huawei gagal'; echo "$RESP" | sed 's/<[^>]*>/ /g' | tr -s ' ' | head -c 500; echo; return 1
}
modem_test(){ echo "=== Huawei E5372 TEST ==="; echo "IP modem : $MODEM_IP"; ping -c 1 -W 2 "$MODEM_IP" >/dev/null 2>&1 || { echo 'ERROR: modem tidak bisa diping'; return 1; }; login_modem || return 1; echo 'OK: login Huawei berhasil'; state_login | sed 's/></>\n</g' | head -30; }
modem_reboot(){
  login_modem || return 1
  XML='<?xml version="1.0" encoding="UTF-8"?><request><Control>1</Control></request>'
  RESP="$(curl -sS --max-time 8 -b "$COOKIE" -c "$COOKIE" -H 'Content-Type: text/xml' -H 'X-Requested-With: XMLHttpRequest' -H "__RequestVerificationToken: $TOKEN" -X POST --data "$XML" "http://$MODEM_IP/api/device/control" 2>/dev/null || true)"
  if echo "$RESP" | grep -q '<response>OK</response>'; then echo 'OK: perintah reboot Huawei diterima'; return 0; fi
  if echo "$RESP" | grep -q '<code>100003</code>\|<code>125002</code>'; then echo 'Token/session ditolak, refresh login dan coba sekali lagi...'; login_modem || return 1; RESP="$(curl -sS --max-time 8 -b "$COOKIE" -c "$COOKIE" -H 'Content-Type: text/xml' -H 'X-Requested-With: XMLHttpRequest' -H "__RequestVerificationToken: $TOKEN" -X POST --data "$XML" "http://$MODEM_IP/api/device/control" 2>/dev/null || true)"; fi
  echo "$RESP" | grep -q '<response>OK</response>' && { echo 'OK: perintah reboot Huawei diterima'; return 0; }
  echo 'ERROR: respons reboot Huawei:'; echo "$RESP"; return 1
}
set_credentials(){
  printf 'Username modem [admin]: '; read USER; [ -n "$USER" ] || USER=admin
  printf 'Password modem: '; stty -echo; read PASS; stty echo; echo
  uci set bh860manager.main.modem_username="$USER"; uci set bh860manager.main.modem_password="$PASS"; uci commit bh860manager; chmod 600 "$CFG"; echo 'Kredensial disimpan di OpenWrt.'
}
both(){ modem_reboot || { echo 'ERROR: modem tidak berhasil direboot. OpenWrt TIDAK direboot.'; return 1; }; echo 'Tunggu 2 detik sebelum reboot OpenWrt...'; sleep 2; sync; reboot; }
case "${1:-}" in
 modem-test) modem_test;; modem-login) login_modem && echo 'OK: login Huawei berhasil';; modem) modem_reboot;; both) both;; set-credentials) set_credentials;; state) get_session_token && state_login;; *) echo 'BH860 Manager'; echo '  bh860managerctl set-credentials'; echo '  bh860managerctl modem-test'; echo '  bh860managerctl modem-login'; echo '  bh860managerctl modem'; echo '  bh860managerctl both'; echo '  bh860managerctl state'; exit 1;; esac
EOC
chmod 700 "$CTL"
cat > "$WATCHDOG" <<'EOC'
#!/bin/sh
set -u
TAG=bh860-manager
enabled="$(uci -q get bh860manager.main.enabled || echo 1)"; interval="$(uci -q get bh860manager.main.check_interval || echo 60)"; fail_limit="$(uci -q get bh860manager.main.fail_limit || echo 5)"; target="$(uci -q get bh860manager.main.target || echo 1.1.1.1)"; recovery_wait="$(uci -q get bh860manager.main.recovery_wait || echo 2)"; cooldown="$(uci -q get bh860manager.main.cooldown || echo 600)"; modem_enabled="$(uci -q get bh860manager.main.modem_enabled || echo 1)"
[ "$enabled" = 1 ] || exit 0
fails=0; last_action=0
logger -t "$TAG" "Started target=$target interval=${interval}s fail_limit=$fail_limit modem=$(uci -q get bh860manager.main.modem_ip || echo 192.168.8.1)"
while :; do
 now=$(date +%s)
 if ping -c 1 -W 3 "$target" >/dev/null 2>&1; then fails=0; else
  fails=$((fails+1)); logger -t "$TAG" "Ping gagal $fails/$fail_limit target=$target"
  if [ "$fails" -ge "$fail_limit" ]; then
   if [ "$last_action" -eq 0 ] || [ $((now-last_action)) -ge "$cooldown" ]; then
    last_action=$now; fails=0
    if [ "$modem_enabled" = 1 ]; then logger -t "$TAG" '5x gagal -> login + reboot Huawei'; /usr/sbin/bh860managerctl modem && logger -t "$TAG" "Huawei reboot command OK; tunggu ${recovery_wait}s" || logger -t "$TAG" 'Huawei reboot GAGAL; OpenWrt tetap direboot sesuai urutan watchdog'; else logger -t "$TAG" 'Modem reboot disabled'; fi
    sleep "$recovery_wait"; logger -t "$TAG" 'Reboot OpenWrt'; sync; reboot; exit 0
   fi
  fi
 fi
 sleep "$interval"
done
EOC
chmod 700 "$WATCHDOG"
cat > "$INIT" <<'EOC'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service(){ [ "$(uci -q get bh860manager.main.enabled)" = 1 ] || return 0; procd_open_instance; procd_set_param command /usr/sbin/bh860manager-watchdog; procd_set_param respawn 3600 5 0; procd_close_instance; }
EOC
chmod 755 "$INIT"
cat > "$LUCI_CTRL" <<'EOC'
module("luci.controller.bh860manager", package.seeall)
function index()
 if not nixio.fs.access("/etc/config/bh860manager") then return end
 entry({"admin","services","bh860manager"}, cbi("bh860manager"), _("Manajer Restart Otomatis BH860"), 80).dependent=true
end
EOC
cat > "$LUCI_MODEL" <<'EOC'
local m=Map("bh860manager","Manajer Restart Otomatis BH860","Pengawas internet ZTE B860H + Huawei E5372. Reboot Huawei melalui API login modem, bukan USB reset.")
local s=m:section(NamedSection,"main","settings","Pengaturan")
local e=s:option(Flag,"enabled","Aktifkan pengawas"); e.rmempty=false
local i=s:option(Value,"check_interval","Interval cek"); i.datatype="uinteger"; i.default="60"
local f=s:option(Value,"fail_limit","Batas gagal"); f.datatype="uinteger"; f.default="5"; f.description="Jumlah ping gagal berturut-turut."
local t=s:option(Value,"target","Ping target"); t.default="1.1.1.1"
local rw=s:option(Value,"recovery_wait","Tunggu sebelum reboot OpenWrt"); rw.datatype="uinteger"; rw.default="2"
local cd=s:option(Value,"cooldown","Jeda minimum"); cd.datatype="uinteger"; cd.default="600"
local mi=s:option(Value,"modem_ip","IP Huawei E5372"); mi.default="192.168.8.1"
local me=s:option(Flag,"modem_enabled","Aktifkan reboot Huawei"); me.default="1"
local mu=s:option(Value,"modem_username","Username Huawei"); mu.default="admin"
local mp=s:option(Value,"modem_password","Password Huawei"); mp.password=true; mp.description="Password tersimpan di /etc/config/bh860manager."
return m
EOC
cat > "$ACL" <<'EOC'
{"luci-app-bh860manager":{"description":"BH860 Manager","read":{"ubus":{}},"write":{}}}
EOC
"$INIT" enable
"$INIT" restart || "$INIT" start
echo
echo '[BH860] INSTALASI SELESAI'
echo 'LANGKAH WAJIB:'
echo '  /usr/sbin/bh860managerctl set-credentials'
echo '  /usr/sbin/bh860managerctl modem-test'
echo '  /usr/sbin/bh860managerctl modem'
echo '  /usr/sbin/bh860managerctl both'
echo 'Watchdog: 60 detik -> 5 gagal -> login Huawei -> reboot Huawei -> reboot OpenWrt'
echo '[BH860] Tidak menggunakan USB authorized reset.'
