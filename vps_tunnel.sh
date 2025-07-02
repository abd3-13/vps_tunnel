#!/bin/bash
# Prechecks
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
command -v awk >/dev/null 2>&1 || {
    echo "❌ awk is not installed. Please install it first."
    exit 1
}
if [ ! -d "$HOME/.config" ]; then
    echo "❌  $HOME/.config dir not found. Creating..."
    mkdir -p "$HOME/.config"
fi


### --- CONFIG --- ###
DEVICE_IP_SUFFIX="40"
VPS_USER="not-set-your_user"
VPS_HOST="not-set-your_vps_address"
EX_PORTS_CNF="$HOME/.config/vps_tunnel-xport.conf"
SSH_PORT="22"
DRY_RUN=false
NON_INTERACTIVE=false
REMOTE_OPTS="-o ServerAliveInterval=10 -o ServerAliveCountMax=3"

pgrep -af "autossh -p [0-9]+ -M 0 -N $REMOTE_OPTS -R 127.0.0" | awk '{print $1}' | xargs kill

# Help message function
show_help() {
cat << EOF

Usage: ${0##*/} [options]

Options:
  -u USER       SSH user (e.g: user)
  -h HOST       VPS hostname or IP (e.g: 146.234.156.34,vps.steven.xyz)
  -p PORT       SSH port on VPS (default: 22)
  -d IP_SUFFIX  Device IP suffix for 127.0.0.X (default: 40)
  -c CONFIG     Path to exclude ports config (default: ~/.config/vps_tunnel-xport.conf)
  -D DRY run    Run it with out creating a Tunnel
  -n headless   Will not prompt users for info and will only use from config file
  -?            Show this help message

Example:
  ${0##*/} -u root -h 146.234.156.34 -p 34898 -d 59 -c ~/.config/vps_exclude.conf
  
EOF
exit 0
}

# Argument handler 
while getopts "u:h:p:d:c:?Dn" opt; do
    case "$opt" in
        u) VPS_USER="$OPTARG" ;;
        h) VPS_HOST="$OPTARG" ;;
        p) SSH_PORT="$OPTARG" ;;
        d) DEVICE_IP_SUFFIX="$OPTARG" ;;
        c) EX_PORTS_CNF="$OPTARG" ;;
        D) DRY_RUN=true ;;
        n) NON_INTERACTIVE=true ;;
        ?) show_help ;;
    esac
done

# Validate DEVICE_IP_SUFFIX (must be between 40 and 60)
if ! [[ "$DEVICE_IP_SUFFIX" =~ ^(4[0-9]|5[0-9]|60)$ ]]; then
    echo "❌ Invalid IP suffix: $DEVICE_IP_SUFFIX,  Must be between 40 and 60 (inclusive)."
    exit 1
fi

DEVICE_IP="127.0.0.${DEVICE_IP_SUFFIX}"

echo "🔧 CONFIG:"
echo -e "   - VPS User: $VPS_USER \t  - VPS Host: $VPS_HOST \t  - SSH Port: $SSH_PORT "
echo -e "   - Tunnel IP: $DEVICE_IP \t  -Config: $EX_PORTS_CNF \t  - Daemon: ${NON_INTERACTIVE}"
echo

exclude_ports=()

# Load saved exclusions
if [[ -f "$EX_PORTS_CNF" ]]; then
    # Validate contents are numeric port numbers
    CNF_valid=true
    while read -r port; do
        [[ "$port" =~ ^[0-9]+$ ]] || {
            echo "❌ Invalid port in exclusion config: '$port'"
            CNF_valid=false
        }
    done < "$EX_PORTS_CNF"

    if $CNF_valid; then
        mapfile -t exclude_ports < "$EX_PORTS_CNF"
        echo -e "📁 Excluded Ports : ${exclude_ports[*]}"
    elif [[ "$NON_INTERACTIVE" == true ]]; then
        echo -e "⚠️ Exclusion config contains invalid data, currently in daemon mode \n❌ Exitting\n"
        exit 1
    else
        echo "⚠️ Exclusion config contains invalid data. Ignoring file."
        exclude_ports=()
    fi
elif [[ "$NON_INTERACTIVE" == true ]]; then
    echo -e "⚠️ Exclusion config missing, currently in daemon mode \n❌ Exitting\n"
    exit 1
fi

echo "📡 Discovering open TCP ports and associated processes..."

# Get list of ports with associated PID/command
mapfile -t port_lines < <(ss -4tlnpH | awk '{print $4, $NF}' | sed 's/),(.*))/))/g; s/users:.."\(.*\)".*/\1/g; s/[0-9\.\*]\+://g' | sort -n -u)

if [ ${#port_lines[@]} -eq 0 ]; then
    echo "❌ No ports discovered — check 'ss' or permissions."
    exit 1
fi



echo -e "🔍 Found services:"

# Collect entries
entries=()
no_of_ports=0
for line in "${port_lines[@]}"; do
    port=$(awk '{print $1}' <<< "$line")
    proc=$(awk '{print $2}' <<< "$line")
    if [[ ! " ${exclude_ports[*]} " =~ " $port " ]]; then
        entries+=("Port ${port} : ${proc}")
        ((no_of_ports++))
    fi
done

#check if there is other ports other than the excluded ones
if [ $no_of_ports -eq 0 ]; then
    echo "❌ No open ports available after exclusions. Nothing to tunnel."
    exit 1
fi

# get the current terminal columns
if command -v tput >/dev/null 2>&1; then
    term_width=$(tput cols)
elif [[ -n "$COLUMNS" ]]; then
    term_width=$COLUMNS
elif term_size=$(stty size 2>/dev/null); then
    term_width=$(awk '{print $2}' <<< "$term_size")
else
    term_width=80  # fallback
fi

# Calculate terminal width and column count
max_entry_len=30   # You can tweak this
cols=$(( term_width / max_entry_len ))
cols=$(( cols > 0 ? cols : 1 ))

# Print entries in columns
for ((i = 0; i < ${#entries[@]}; i++)); do
    printf "%-30s" "${entries[$i]}"
    (( (i + 1) % cols == 0 )) && echo
done
echo

if ! $NON_INTERACTIVE; then
    # Prompt for additional exclusions
    read -rp "🚫 Enter ports to exclude (space-separated): " -a exclude_input
    
    # Combine and deduplicate
    exclude_ports+=("${exclude_input[@]}")
    exclude_ports=($(printf "%s\n" "${exclude_ports[@]}" | sort -n | uniq))
    
    ### --- SAVE FOR NEXT RUN --- ###
    read -p "💾 Save these exclusions for next time? (y/n): " save
    if [[ "$save" == "y" ]]; then
        printf "%s\n" "${exclude_ports[@]}" > "$EX_PORTS_CNF"
    fi
fi

### --- BUILD AUTOSSH COMMAND --- ###
SKIP_PORTS=""
FORW_PORTS=""
CANG_PORTS=""

# Get list of port used in vps
mapfile -t vps_used_ports < <(ssh -p "$SSH_PORT" -o ConnectTimeout=5 -o BatchMode=yes ${VPS_USER}@${VPS_HOST} "ss -4tlnH | awk '{split(\$4,a,\":\"); print a[2]}'")

# Build port forwarding list
for line in "${port_lines[@]}"; do
    port=$(awk '{print $1}' <<< "$line")

    # Skip if excluded
    if [[ " ${exclude_ports[*]} " =~ " $port " ]]; then
        SKIP_PORTS+="$port, "
        continue
    fi

    # Check if the port is already used on VPS
    if [[ " ${vps_used_ports[*]} " =~ " $port " ]]; then
        nport="${DEVICE_IP_SUFFIX}${port}"
        CANG_PORTS+="$port→$nport, "
    else
        nport="$port"
    fi

    # Add the tunnel
    REMOTE_OPTS+=" -R ${DEVICE_IP}:${nport}:127.0.0.1:${port}"
    FORW_PORTS+="$nport, "
done

echo -e "\n✅ Forwarding port: $FORW_PORTS"

echo " ❌ Skipped: $SKIP_PORTS"
echo " ✅ Changed: $CANG_PORTS"

echo -e "\n🚀 Launching autossh..."

if $DRY_RUN; then
    echo -e "\n🔍 Dry Run Mode:"
    echo "SSH Command: autossh -p $SSH_PORT -M 0 -N $REMOTE_OPTS $VPS_USER@$VPS_HOST"
    exit 0
fi

exec autossh -p "$SSH_PORT" -M 0 -N $REMOTE_OPTS ${VPS_USER}@${VPS_HOST} &
echo "$!" > "/tmp/vps_tunnel_${DEVICE_IP_SUFFIX}-$!.pid"
