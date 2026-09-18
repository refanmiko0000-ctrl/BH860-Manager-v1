#!/bin/sh
# BH860 Manager - one-line installer for OpenWrt 23.05+
# Usage:
#   sh -c "$(wget -qO- https://raw.githubusercontent.com/USERNAME/BH860-Manager/main/install.sh)"
#
# Features:
# - Internet watchdog
# - Direct Huawei HiLink reboot through /api/device/control
# - Reboot OpenWrt after modem reboot command
# - LuCI page under Services/Layanan
# - Manual buttons: modem / OpenWrt / both

set -e

say() { echo "[BH860] $*"; }

[ "$(id -u)" = "0" ] || {
    echo "ERROR: jalankan sebagai root."
    exit 1
}

say "Memasang BH860 Manager..."

# curl is required for Huawei HiLink API.
if ! command -v curl >/dev/null 2>&1; then
    say "curl belum ada, mencoba memasang..."
    opkg update >/dev/null 2>&1 || true
    opkg install curl
fi

command -v curl >/dev/null 2>&1 || {
    echo "ERROR: curl tidak tersedia."
    exit 1
}

mkdir -p \
    /etc/config \
    /etc/init.d \
    /usr/sbin \
    /usr/lib/lua/luci/controller \
    /usr/lib/lua/luci/model/cbi \
    /usr/lib/lua/luci/view/bh860manager \
    /usr/share/rpcd/acl.d

cat > /etc/config/bh860manager <<'EOF'
config settings 'main'
	option enabled '1'
	option check_interval '60'
	option fail_limit '5'
	option target '1.1.1.1'
	option recovery_wait '2'
	option cooldown '600'
	option modem_ip '192.168.8.1'
	option modem_enabled '1'
EOF
chmod 600 /etc/config/bh860manager

cat > /etc/init.d/bh860manager <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
	[ "$(uci -q get bh860manager.main.enabled)" = "1" ] || return 0
	procd_open_instance
	procd_set_param command /usr/sbin/bh860manager-watchdog
	procd_set_param respawn 3600 5 0
	procd_close_instance
}
EOF
chmod 755 /etc/init.d/bh860manager

cat > /usr/sbin/bh860managerctl <<'EOF'
#!/bin/sh

TAG="bh860-manager"
MODEM_IP="$(uci -q get bh860manager.main.modem_ip 2>/dev/null)"
[ -n "$MODEM_IP" ] || MODEM_IP="192.168.8.1"

log() { logger -t "$TAG" "$*"; }

extract_xml() {
	sed -n "s:.*<$1>\\([^<]*\\)</$1>.*:\\1:p" | head -n 1
}

get_session_token() {
	resp="$(curl -fsS --connect-timeout 2 --max-time 5 \
		"http://$MODEM_IP/api/webserver/SesTokInfo" 2>/dev/null)" || resp=""

	session="$(printf '%s' "$resp" | extract_xml SesInfo)"
	token="$(printf '%s' "$resp" | extract_xml TokInfo)"

	if [ -z "$token" ]; then
		resp2="$(curl -fsS --connect-timeout 2 --max-time 5 \
			"http://$MODEM_IP/api/webserver/token" 2>/dev/null)" || resp2=""
		token="$(printf '%s' "$resp2" |
			sed -n 's:.*<token>\\([^<]*\\)</token>.*:\\1:p' | head -n 1)"
	fi

	[ -n "$token" ] || return 1
	printf '%s|%s\n' "$session" "$token"
}

modem_test() {
	info="$(get_session_token)" || {
		echo "ERROR: Huawei HiLink API tidak merespons."
		echo "IP modem: $MODEM_IP"
		return 1
	}

	session="${info%%|*}"
	token="${info#*|}"

	echo "OK: Huawei HiLink API terdeteksi"
	echo "IP modem: $MODEM_IP"
	[ -n "$session" ] && echo "Session: tersedia"
	[ -n "$token" ] && echo "Token: tersedia"
}

modem_reboot() {
	info="$(get_session_token)" || {
		log "Gagal mengambil session/token Huawei $MODEM_IP"
		echo "ERROR: gagal mengambil session/token Huawei"
		return 1
	}

	session="${info%%|*}"
	token="${info#*|}"

	if [ -n "$session" ]; then
		result="$(curl -sS --connect-timeout 2 --max-time 5 \
			-X POST \
			-H "Content-Type: text/xml" \
			-H "__RequestVerificationToken: $token" \
			-H "Cookie: $session" \
			--data '<request><Control>1</Control></request>' \
			"http://$MODEM_IP/api/device/control" 2>/dev/null)" || result=""
	else
		result="$(curl -sS --connect-timeout 2 --max-time 5 \
			-X POST \
			-H "Content-Type: text/xml" \
			-H "__RequestVerificationToken: $token" \
			--data '<request><Control>1</Control></request>' \
			"http://$MODEM_IP/api/device/control" 2>/dev/null)" || result=""
	fi

	case "$result" in
		*"<response>OK</response>"*|*"OK"*)
			log "Perintah reboot Huawei berhasil dikirim"
			echo "OK: perintah reboot Huawei berhasil dikirim"
			return 0
			;;
		"")
			log "Huawei menutup koneksi setelah perintah reboot; kemungkinan reboot dimulai"
			echo "WARN: koneksi ditutup modem; reboot kemungkinan dimulai"
			return 0
			;;
		*)
			log "Respons reboot Huawei: $result"
			echo "ERROR: respons Huawei: $result"
			return 1
			;;
	esac
}

router_reboot() {
	log "Reboot OpenWrt"
	sync
	sleep 1
	/sbin/reboot
}

case "$1" in
	modem-test) modem_test ;;
	modem) modem_reboot ;;
	router) router_reboot ;;
	both)
		modem_reboot || true
		sleep 1
		router_reboot
		;;
	*)
		echo "Usage: $0 {modem-test|modem|router|both}"
		exit 2
		;;
esac
EOF
chmod 755 /usr/sbin/bh860managerctl

cat > /usr/sbin/bh860manager-watchdog <<'EOF'
#!/bin/sh

TAG="bh860-manager"

getopt() {
	uci -q get "bh860manager.main.$1" 2>/dev/null
}

log() {
	logger -t "$TAG" "$*"
}

main() {
	[ "$(getopt enabled)" = "1" ] || exit 0

	interval="$(getopt check_interval)"
	case "$interval" in ''|*[!0-9]*) interval=60;; esac

	limit="$(getopt fail_limit)"
	case "$limit" in ''|*[!0-9]*) limit=5;; esac

	target="$(getopt target)"
	[ -n "$target" ] || target="1.1.1.1"

	waittime="$(getopt recovery_wait)"
	case "$waittime" in ''|*[!0-9]*) waittime=2;; esac

	cooldown="$(getopt cooldown)"
	case "$cooldown" in ''|*[!0-9]*) cooldown=600;; esac

	[ "$interval" -ge 10 ] || interval=10
	[ "$limit" -ge 2 ] || limit=2
	[ "$waittime" -ge 1 ] || waittime=1
	[ "$cooldown" -ge 60 ] || cooldown=60

	fails=0
	last_action=0

	log "Started target=$target interval=${interval}s fail_limit=$limit modem=$(getopt modem_ip)"

	while :; do
		if ping -c 1 -W 3 "$target" >/dev/null 2>&1; then
			[ "$fails" -gt 0 ] && log "Internet recovered"
			fails=0
		else
			fails=$((fails + 1))
			log "Ping failed $fails/$limit for $target"
		fi

		if [ "$fails" -ge "$limit" ]; then
			now="$(date +%s)"
			if [ $((now - last_action)) -ge "$cooldown" ]; then
				last_action="$now"
				log "Failure threshold reached; direct Huawei HiLink reboot"
				/usr/sbin/bh860managerctl modem
				sleep "$waittime"
				log "Rebooting OpenWrt"
				sync
				/sbin/reboot
				exit 0
			else
				log "Cooldown active; no reboot"
				fails=0
			fi
		fi

		sleep "$interval"
	done
}

main
EOF
chmod 755 /usr/sbin/bh860manager-watchdog

cat > /usr/lib/lua/luci/controller/bh860manager.lua <<'EOF'
module("luci.controller.bh860manager", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/bh860manager") then return end

	entry({"admin","services","bh860manager"},
		cbi("bh860manager"),
		_("Manajer Restart Otomatis BH860"), 90).dependent = true

	entry({"admin","services","bh860manager","actions"},
		call("actions")).leaf = true
end

function actions()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local action = http.formvalue("action")

	if action ~= "modem" and action ~= "router" and action ~= "both" then
		http.status(400, "Bad Request")
		http.write("Invalid action")
		return
	end

	sys.call("/usr/sbin/bh860managerctl " .. action ..
		" >/tmp/bh860manager-action.log 2>&1")

	http.redirect(luci.dispatcher.build_url("admin","services","bh860manager"))
end
EOF

cat > /usr/lib/lua/luci/model/cbi/bh860manager.lua <<'EOF'
local m = Map("bh860manager",
	translate("Manajer Restart Otomatis BH860"),
	translate("Watchdog internet untuk OpenWrt + Huawei HiLink. Jika koneksi gagal berturut-turut sesuai batas, modem direboot melalui API HiLink lalu OpenWrt direboot."))

local s = m:section(NamedSection, "main", "settings",
	translate("Pengaturan Watchdog"))
s.anonymous = true

local e = s:option(Flag, "enabled", translate("Aktifkan pengawas"))
e.rmempty = false

local i = s:option(Value, "check_interval", translate("Interval cek (detik)"))
i.datatype = "uinteger"

local f = s:option(Value, "fail_limit", translate("Batas gagal berturut-turut"))
f.datatype = "uinteger"

local t = s:option(Value, "target", translate("Ping target"))
t.description = translate("Contoh: 1.1.1.1")

local w = s:option(Value, "recovery_wait",
	translate("Jeda sebelum reboot OpenWrt (detik)"))
w.datatype = "uinteger"

local c = s:option(Value, "cooldown",
	translate("Jeda minimum antar aksi (detik)"))
c.datatype = "uinteger"

local ip = s:option(Value, "modem_ip",
	translate("IP Huawei HiLink"))
ip.datatype = "ipaddr"

local me = s:option(Flag, "modem_enabled",
	translate("Gunakan reboot modem HiLink"))
me.rmempty = false

function m.on_after_commit(self)
	os.execute("/etc/init.d/bh860manager restart >/dev/null 2>&1")
end

local a = m:section(SimpleSection, translate("Kontrol Manual"))
a.template = "bh860manager/actions"

return m
EOF

cat > /usr/lib/lua/luci/view/bh860manager/actions.htm <<'EOF'
<div class="cbi-section">
	<div class="cbi-section-descr">
		Restart manual.
	</div>

	<form method="post"
	 action="<%=luci.dispatcher.build_url('admin','services','bh860manager','actions')%>"
	 style="display:inline-block;margin:0 8px 8px 0;">
		<input type="hidden" name="action" value="modem" />
		<input class="btn cbi-button cbi-button-apply" type="submit"
		 value="<%:Restart Modem Huawei%>" />
	</form>

	<form method="post"
	 action="<%=luci.dispatcher.build_url('admin','services','bh860manager','actions')%>"
	 style="display:inline-block;margin:0 8px 8px 0;">
		<input type="hidden" name="action" value="router" />
		<input class="btn cbi-button cbi-button-reset" type="submit"
		 value="<%:Restart OpenWrt%>" />
	</form>

	<form method="post"
	 action="<%=luci.dispatcher.build_url('admin','services','bh860manager','actions')%>"
	 style="display:inline-block;margin:0 8px 8px 0;"
	 onsubmit="return confirm('Restart modem Huawei dan OpenWrt sekarang?');">
		<input type="hidden" name="action" value="both" />
		<input class="btn cbi-button cbi-button-remove" type="submit"
		 value="<%:Restart Modem + OpenWrt%>" />
	</form>
</div>
EOF

cat > /usr/share/rpcd/acl.d/luci-app-bh860manager.json <<'EOF'
{
	"luci-app-bh860manager": {
		"description": "BH860 Manager permissions",
		"read": { "uci": [ "bh860manager" ] },
		"write": { "uci": [ "bh860manager" ] }
	}
}
EOF

/etc/init.d/bh860manager enable
/etc/init.d/bh860manager restart
/etc/init.d/rpcd restart 2>/dev/null || true
rm -rf /tmp/luci-* /tmp/*.index 2>/dev/null || true

echo
say "INSTALASI SELESAI"
echo
echo "LuCI:"
echo "  http://192.168.1.1/cgi-bin/luci/admin/services/bh860manager"
echo
echo "Tes API modem tanpa reboot:"
echo "  /usr/sbin/bh860managerctl modem-test"
echo
echo "Tes reboot modem:"
echo "  /usr/sbin/bh860managerctl modem"
echo
echo "Reboot modem + OpenWrt:"
echo "  /usr/sbin/bh860managerctl both"
echo
echo "Watchdog:"
echo "  cek internet tiap 60 detik"
echo "  5 kali gagal -> reboot Huawei -> reboot OpenWrt"
echo
