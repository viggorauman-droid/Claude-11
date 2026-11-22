#!/usr/bin/env bash
# wifi-diagnose.sh — find what's slowing down your WiFi (macOS + Linux)
# Usage: bash wifi-diagnose.sh        (some checks give more detail with sudo)
# Read-only: changes nothing on your system.

set -u
OS="$(uname -s)"
ISSUES=()
flag() { ISSUES+=("$1"); echo "  [!] $1"; }
ok()   { echo "  [ok] $1"; }
hdr()  { echo; echo "== $1 =="; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------- helpers ----------
ping_stats() { # host count -> prints "avg loss%" (or empty)
  local out
  out="$(ping -c "$2" -q "$1" 2>/dev/null)" || true
  local loss avg
  loss="$(echo "$out" | grep -Eo '[0-9.]+% packet loss' | grep -Eo '^[0-9.]+')"
  avg="$(echo "$out" | awk -F'/' '/min\/avg|round-trip|rtt/ {print $5}')"
  [ -n "${loss:-}" ] && echo "${avg:-0} $loss"
}
num_gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
num_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }

# ---------- 1. Radio link ----------
hdr "1. WiFi link (signal, noise, band, channel, speed)"
RSSI=""; NOISE=""; CHAN=""; RATE=""; IFACE=""
if [ "$OS" = "Darwin" ]; then
  IFACE="$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')"
  INFO="$(system_profiler SPAirPortDataType 2>/dev/null | awk '/Current Network Information:/{f=1;next} f&&/Other Local Wi-Fi Networks:/{exit} f')"
  echo "$INFO" | sed 's/^ */  /' | head -20
  SN="$(echo "$INFO" | awk -F': ' '/Signal \/ Noise/{print $2; exit}')"
  RSSI="$(echo "$SN" | grep -Eo '^-?[0-9]+')"
  NOISE="$(echo "$SN" | grep -Eo '/ *-?[0-9]+' | grep -Eo '\-?[0-9]+')"
  CHAN="$(echo "$INFO" | awk -F': ' '/Channel:/{print $2; exit}' | grep -Eo '^[0-9]+')"
  RATE="$(echo "$INFO" | awk -F': ' '/Transmit Rate/{print $2; exit}')"
  PHY="$(echo "$INFO" | awk -F': ' '/PHY Mode/{print $2; exit}')"
  case "$PHY" in *802.11b*|*802.11g*|*802.11a\ *) flag "Old WiFi standard in use ($PHY) — very low max speed";; esac
elif have nmcli; then
  IFACE="$(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="wifi"{print $1; exit}')"
  LINE="$(nmcli -t -f IN-USE,SSID,CHAN,SIGNAL,RATE,SECURITY dev wifi list 2>/dev/null | grep '^\*' | head -1)"
  echo "  $LINE"
  CHAN="$(echo "$LINE" | cut -d: -f3)"; RATE="$(echo "$LINE" | cut -d: -f5)"
  SIGPCT="$(echo "$LINE" | cut -d: -f4)"
  if have iw && [ -n "$IFACE" ]; then
    iw dev "$IFACE" link 2>/dev/null | sed 's/^/  /'
    RSSI="$(iw dev "$IFACE" link 2>/dev/null | awk '/signal:/{print $2}')"
  fi
  [ -z "$RSSI" ] && [ -n "${SIGPCT:-}" ] && RSSI=$(( SIGPCT / 2 - 100 ))
else
  echo "  (no nmcli/system_profiler found — skipping radio checks)"
fi

if [ -n "$RSSI" ]; then
  if   [ "$RSSI" -le -75 ]; then flag "Weak signal ($RSSI dBm). Move closer to router, remove obstructions, or add a mesh node/extender"
  elif [ "$RSSI" -le -67 ]; then flag "Mediocre signal ($RSSI dBm). OK for browsing, not for video calls/streaming"
  else ok "Signal strength $RSSI dBm"; fi
fi
if [ -n "$RSSI" ] && [ -n "$NOISE" ]; then
  SNR=$(( RSSI - NOISE ))
  if [ "$SNR" -lt 20 ]; then flag "Low signal-to-noise ratio (${SNR} dB) — interference (microwaves, baby monitors, Bluetooth, neighbours)"
  else ok "SNR ${SNR} dB"; fi
fi
if [ -n "$CHAN" ]; then
  if [ "$CHAN" -le 14 ]; then
    flag "Connected on 2.4 GHz (channel $CHAN) — slower and more crowded. Use the 5/6 GHz network if your router has one"
    case "$CHAN" in 1|6|11) ;; *) flag "2.4 GHz channel $CHAN overlaps neighbours — set router to channel 1, 6 or 11";; esac
  else ok "On 5/6 GHz (channel $CHAN)"; fi
fi
[ -n "$RATE" ] && echo "  Link rate: $RATE (Mbps)"
if [ -n "$RATE" ]; then R="$(echo "$RATE" | grep -Eo '^[0-9]+')"
  [ -n "$R" ] && [ "$R" -lt 100 ] && flag "Low link rate (${R} Mbps) — your device-to-router connection caps your speed"
fi

# ---------- 2. Congestion ----------
hdr "2. Channel congestion (nearby networks)"
if [ "$OS" = "Darwin" ]; then
  NEAR="$(system_profiler SPAirPortDataType 2>/dev/null | awk '/Other Local Wi-Fi Networks:/{f=1} f&&/Channel:/{split($2,a," "); print a[1]}')"
elif have nmcli; then
  NEAR="$(nmcli -t -f IN-USE,CHAN dev wifi list 2>/dev/null | grep -v '^\*' | cut -d: -f2)"
fi
if [ -n "${NEAR:-}" ]; then
  echo "  Networks per channel:"; echo "$NEAR" | sort -n | uniq -c | sort -rn | head -8 | sed 's/^/   /'
  if [ -n "$CHAN" ]; then
    SAME="$(echo "$NEAR" | grep -cx "$CHAN")"
    if [ "$SAME" -ge 5 ]; then flag "$SAME other networks share your channel $CHAN — pick a quieter channel in router settings"
    else ok "$SAME other networks on your channel"; fi
  fi
else echo "  (could not scan)"; fi

# ---------- 3. Where is the slowness: LAN vs ISP ----------
hdr "3. Latency & packet loss (router vs internet)"
if [ "$OS" = "Darwin" ]; then GW="$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')"
else GW="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"; fi
echo "  Router/gateway: ${GW:-unknown}"
if [ -n "$GW" ]; then
  read -r GAVG GLOSS <<<"$(ping_stats "$GW" 20)"
  echo "  To router:   avg ${GAVG:-?} ms, loss ${GLOSS:-?}%"
  [ -n "${GAVG:-}" ] && num_gt "$GAVG" 10 && flag "High latency to your own router (${GAVG} ms) — WiFi link problem, not ISP"
  [ -n "${GLOSS:-}" ] && num_gt "$GLOSS" 1 && flag "Packet loss to router (${GLOSS}%) — interference or weak signal"
fi
read -r IAVG ILOSS <<<"$(ping_stats 1.1.1.1 20)"
echo "  To internet: avg ${IAVG:-?} ms, loss ${ILOSS:-?}%"
[ -n "${IAVG:-}" ] && num_gt "$IAVG" 60 && flag "High internet latency (${IAVG} ms) — check ISP / modem"
[ -n "${ILOSS:-}" ] && num_gt "$ILOSS" 1 && flag "Packet loss to internet (${ILOSS}%) — if router loss is 0, the ISP/modem is the culprit"

# ---------- 4. DNS ----------
hdr "4. DNS speed"
if have dig; then
  for d in example.com wikipedia.org; do
    T="$(dig +tries=1 +time=3 "$d" 2>/dev/null | awk '/Query time/{print $4}')"
    echo "  $d: ${T:-timeout} ms"
    if [ -z "$T" ] || [ "$T" -gt 150 ]; then flag "Slow DNS (${T:-timeout} ms for $d) — try 1.1.1.1 or 8.8.8.8 as DNS server"; break; fi
  done
else echo "  (dig not installed — skipping)"; fi

# ---------- 5. Bufferbloat ----------
hdr "5. Bufferbloat (latency while downloading)"
if have curl; then
  curl -s -o /dev/null --max-time 12 https://speed.cloudflare.com/__down?bytes=200000000 &
  CP=$!; sleep 2
  read -r LAVG _ <<<"$(ping_stats 1.1.1.1 8)"
  kill $CP 2>/dev/null; wait $CP 2>/dev/null
  echo "  Idle: ${IAVG:-?} ms  →  under load: ${LAVG:-?} ms"
  if [ -n "${IAVG:-}" ] && [ -n "${LAVG:-}" ] && num_gt "$(awk -v a="$LAVG" -v b="$IAVG" 'BEGIN{print a-b}')" 100; then
    flag "Bufferbloat: latency jumps under load — enable SQM / Smart Queue / QoS on your router"
  elif [ -n "${LAVG:-}" ]; then ok "Latency stays stable under load"
  else echo "  (could not measure)"; fi
  hdr "5b. Download speed"
  BPS="$(curl -s -o /dev/null --max-time 15 -w '%{speed_download}' https://speed.cloudflare.com/__down?bytes=50000000)"
  MBPS="$(awk -v b="${BPS:-0}" 'BEGIN{printf "%.1f", b*8/1e6}')"
  echo "  ~${MBPS} Mbps (single stream)"
fi

# ---------- 6. Bandwidth hogs on this computer ----------
hdr "6. What on this computer is using the network"
if [ "$OS" = "Darwin" ]; then
  nettop -P -L 1 -J bytes_in,bytes_out -x 2>/dev/null | sort -t, -k2 -nr 2>/dev/null | head -10 | sed 's/^/  /'
elif have nethogs && [ "$(id -u)" = 0 ]; then
  timeout 6 nethogs -t -c 3 2>/dev/null | tail -10 | sed 's/^/  /'
elif have ss; then
  echo "  Processes with most open connections (install nethogs + sudo for bytes):"
  ss -tunp 2>/dev/null | grep -Eo 'users:\(\("[^"]+' | cut -d'"' -f2 | sort | uniq -c | sort -rn | head -10 | sed 's/^/   /'
fi
for p in Dropbox OneDrive "Google Drive" iCloud bird backupd steam Steam qbittorrent transmission utorrent "Windows Update"; do
  pgrep -if "$p" >/dev/null 2>&1 && flag "Running: $p — syncing/downloading can saturate your connection"
done

# ---------- 7. VPN / proxy ----------
hdr "7. VPN / tunnels"
if [ "$OS" = "Darwin" ]; then TUN="$(ifconfig 2>/dev/null | grep -Eo '^utun[0-9]+' | while read -r u; do ifconfig "$u" | grep -q 'inet ' && echo "$u"; done)"
else TUN="$(ip -o link 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(tun|wg|ppp|tailscale|proton|nordlynx)')"; fi
if [ -n "$TUN" ]; then flag "Active VPN/tunnel interface(s): $(echo $TUN) — VPNs add latency and cut throughput"
else ok "No active VPN tunnel"; fi

# ---------- 8. Devices on the network ----------
hdr "8. Other devices on your network"
N="$(arp -an 2>/dev/null | grep -vc incomplete)"
echo "  ~$N devices seen in ARP table"
[ "${N:-0}" -gt 25 ] && flag "Many devices ($N) share your WiFi — streaming/cameras/updates on them compete for airtime"

# ---------- Summary ----------
hdr "SUMMARY"
if [ ${#ISSUES[@]} -eq 0 ]; then echo "  No obvious problems found. If it's still slow, reboot router/modem and compare with a wired connection."
else printf '  - %s\n' "${ISSUES[@]}"; fi
echo
