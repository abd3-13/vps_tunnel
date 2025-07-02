#!/bin/bash
# Check existence of needed commands
command -v autossh >/dev/null 2>&1 || {
    echo "❌ autossh is not installed. Please install it first."
    exit 1
}
command -v sed >/dev/null 2>&1 || {
    echo "❌ sed is not installed. Please install it first."
    exit 1
}
command -v ss >/dev/null 2>&1 || {
    echo "❌ ss is not installed. Please install it first."
    exit 1
}
command -v read >/dev/null 2>&1 || {
    echo "❌ read is not installed. Please install it first."
    exit 1
}
[ -d $HOME/.config ]; { echo "❌  $HOME/.config dir not found. Creating..."; mkdir -p $HOME/.config; }

### --- CONFIG --- ###
DEVICE_IP_SUFFIX="58"
VPS_USER="your_user"
VPS_HOST="your_vps_address"
EX_PORTS_CNF="$HOME/.config/vps_tunnel-xport.conf"
SSH_PORT="22"

# Help message function
show_help() {
cat << EOF
Usage: $0 [options]

Options:
  -u USER       SSH user (default: root)
  -h HOST       VPS hostname or IP (default: gate.lab)
  -P PORT       SSH port on VPS (default: 22)
  -d IP_SUFFIX  Device IP suffix for 127.0.0.X (default: 58)
  -c CONFIG     Path to exclude ports config (default: ~/.config/vps_tunnel-xport.conf)
  -?            Show this help message

Example:
  $0 -u root -h 146.234.156.34 -P 34898 -d 59 -c ~/.config/vps_exclude.conf
EOF
exit 0
}

# Argument handler 
while getopts "u:h:P:d:c:?" opt; do
    case "$opt" in
        u) VPS_USER="$OPTARG" ;;
        h) VPS_HOST="$OPTARG" ;;
        P) SSH_PORT="$OPTARG" ;;
        d) DEVICE_IP_SUFFIX="$OPTARG" ;;
        c) EX_PORTS_CNF="$OPTARG" ;;
        ?) show_help ;;
    esac
done

DEVICE_IP="127.0.0.${DEVICE_IP_SUFFIX}"

echo "🔧 CONFIG:"
echo "   - VPS User: $VPS_USER"
echo "   - VPS Host: $VPS_HOST"
echo "   - SSH Port: $SSH_PORT"
echo "   - Tunnel IP: $DEVICE_IP"
echo "   - Exclusion Config: $EX_PORTS_CNF"
echo


echo "📡 Discovering open TCP ports and associated processes..."

# Get list of ports with associated PID/command
mapfile -t port_lines < <(ss -tlnpH | awk '{print $4, $NF}' | sed 's/),(.*))/))/g; s/users:.."\(.*\)".*/\1/g; s/[0-9\.\*]\+://g; s/\[::\]://g' | sort -n -u)

if [ ${#port_lines[@]} -eq 0 ]; then
    echo "❌ No ports discovered — check 'ss' or permissions."
    exit 1
fi


exclude_ports=()

# Load saved exclusions
if [[ -f "$EX_PORTS_CNF" ]]; then
    exclude_ports+=($(cat $EX_PORTS_CNF))
    echo -e "📁 Loaded excluded ports from config: ${exclude_ports[*]}"
fi


echo "🔍 Found services:"
for line in "${port_lines[@]}"; do
    port=$(awk '{print $1}' <<< "$line")
    if [[ ! " ${exclude_ports[*]} " =~ " $port " ]]; then
        echo -e "   - Port $port \t → $(awk '{print $2}' <<< "$line")"
    fi    
done
echo


# Prompt for additional exclusions
read -rp "🚫 Enter additional ports to exclude (space-separated): " -a exclude_input

# Combine and deduplicate
exclude_ports+=("${exclude_input[@]}")
exclude_ports=($(printf "%s\n" "${exclude_ports[@]}" | sort -n | uniq))

### --- SAVE FOR NEXT RUN --- ###
read -p "💾 Save these exclusions for next time? (y/n): " save
if [[ "$save" == "y" ]]; then
    printf "%s\n" "${exclude_ports[@]}" > "$EX_PORTS_CNF"
fi


### --- BUILD AUTOSSH COMMAND --- ###
REMOTE_OPTS=""
SKIP_PORTS=""
FORW_PORTS=""

for line in "${port_lines[@]}"; do
    port=$(awk '{print $1}' <<< "$line")
    if [[ " ${exclude_ports[*]} " =~ " $port " ]]; then
      #  echo "❌ Skipping excluded port: $port"
        SKIP_PORTS+="${port}, "
        continue
    fi
    FORW_PORTS+="${port}, "
    REMOTE_OPTS+=" -R ${DEVICE_IP}:${port}:127.0.0.1:${port}"
done

echo -e "\n✅ Forwarding port: $FORW_PORTS"

echo -e "\n ❌ Skipped: $SKIP_PORTS"

echo -e "\n🚀 Launching autossh..."
exec autossh -p "$SSH_PORT" -M 0 -N -o "ExitOnForwardFailure=yes" $REMOTE_OPTS ${VPS_USER}@${VPS_HOST} &
echo "$!" > "/tmp/vps_tunnel_${DEVICE_IP_SUFFIX}.pid"
