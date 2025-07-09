#!/bin/bash

### --- CONFIG --- ###
DEVICE_IP_SUFFIX="40"
VPS_USER="not-set-your_user"
VPS_HOST="not-set-your_vps_address"
EX_PORTS_CNF="$HOME/.config/vps_tunnel-xport.conf"
SSH_PORT="22"
DRY_RUN=false
NON_INTERACTIVE=false
REMOTE_OPTS="-4 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"


prechecks() {
    for cmd in autossh sed ss awk sort uniq read ssh cat curl while mapfile printf echo; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "❌ $cmd is not installed. Please install it."
            exit 1
        }
    done
    mkdir -p "$HOME/.config"
}

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

# Check docker ports for if they are not placeholders
check_ports_alive() {
    local port=$1
    local proc=$2

    [[ $proc == "docker-proxy" ]] || return 0

    # Check http
    curl -s --max-time 2 --head "http://127.0.0.1:$port" | grep -qE "^HTTP/(2(\.0)?|1\.[01]) [234].." && return 0

    # check https
    curl -sk --max-time 2 --head "https://127.0.0.1:$port" | grep -qE "^HTTP/(2(\.0)?|1\.[01]) [234].." && return 0

    return 1
}

# work on port exlude config file, check, validating, importing
port_conf_file() {
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

}

# utilize ss from iproute2 to discover port bing used
discover_ports() {
    echo "📡 Discovering open TCP ports and associated processes..."
    
    # Get list of ports with associated PID/command
    # previous "awk '{print $4, $NF}' | sed 's/),(.*))/))/g; s/users:.."\(.*\)".*/\1/g; s/[0-9\.\*]\+://g; s/[0-9\.]\+%lo://g'"
    
    mapfile -t port_lines < <(ss -tlnpH | awk -F '[ :\"]+' '{print $5, $10}' | sort -n -u)
    
    if [ ${#port_lines[@]} -eq 0 ]; then
        echo "❌ No ports discovered — check 'ss' or permissions."
        exit 1
    fi
    
    echo -e "🔍 Found services: ${#port_lines[@]} | Excluded : ${#exclude_ports[@]} "
}

#get terminal width and Calculate the appropriate columns to print
term_canvas() { 
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
    cols=$(( term_width / max_entry_len ))
    cols=$(( cols > 0 ? cols : 1 ))
}

#prompt user for port exclusionsand saving of current exclusion to config file
user_ports() {
    if ! $NON_INTERACTIVE; then
        # Prompt for additional exclusions
        read -rp "🚫 Enter ports to exclude (space-separated): " -a exclude_input
        if [ ${#exclude_input[@]} -eq 0 ]; then
            return
        fi
        # Combine and deduplicate
        exclude_ports+=("${exclude_input[@]}")
        exclude_ports=($(printf "%s\n" "${exclude_ports[@]}" | sort -n | uniq))
        
        # SAVE FOR NEXT
        read -p "💾 Save these exclusions for next time? (y/n): " save
        if [[ "$save" == "y" ]]; then
            printf "%s\n" "${exclude_ports[@]}" > "$EX_PORTS_CNF"
        fi
    fi
}

check_vps_ports() {
    echo -e "🔍 Checking VPS ports ..."
    # Get list of port used in vps
    mapfile -t vps_used_ports < <(ssh -4 -p "$SSH_PORT" -o ConnectTimeout=5 -o BatchMode=yes ${VPS_USER}@${VPS_HOST} "ss -4tlnH | awk '{split(\$4,a,\":\"); print a[2]}'")

    if [ ${#vps_used_ports[@]} -eq 0 ]; then
        echo "NO ports is being used on the VPS"
    fi
}

#run Precheck functions to check for need commands and dirs
prechecks

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

port_lines=()
exclude_ports=()
vps_used_ports=()
entries=()
no_of_ports=0
max_entry_len=30   # You can tweak this
SKIP_PORTS=""
FORW_PORTS=""
CANG_PORTS=""

#call config function to work on the config file
port_conf_file

#call discover function to locate port being used in the system
discover_ports

#call function that get and calculate termianl dimensions for column print
term_canvas

# Collect entries

for line in "${port_lines[@]}"; do
    port=$(awk '{print $1}' <<< "$line")
    proc=$(awk '{print $2}' <<< "$line")

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        echo "⚠️ Skipping invalid port: $port"
        continue
    fi

    check_ports_alive $port "$proc" || {
        exclude_ports+=(${port})
        continue
    }

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

# Print entries in columns
for ((i = 0; i < ${#entries[@]}; i++)); do
    printf "%-30s" "${entries[$i]}"
    (( (i + 1) % cols == 0 )) && echo
done
echo

#call function that ask the user what other to excluded and save it?
user_ports

### --- BUILD AUTOSSH COMMAND --- ###

check_vps_ports

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
        OFFSET=$(( DEVICE_IP_SUFFIX * 1000 ))
        nport=$(( OFFSET + port ))
        [[ $nport > 65535 ]] && echo "$nport is above max port"
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
    echo -e "\n🔍 Dry Run Mode \n SSH Command: autossh -p $SSH_PORT -M 0 -N $REMOTE_OPTS $VPS_USER@$VPS_HOST"
    exit 0
fi

#terminate previous instances if not on dry run
pgrep -af "autossh -p $SSH_PORT -M 0 -N $REMOTE_OPTS -R 127.0.0" | awk '{print $1}' | xargs kill 2>/dev/null
exec autossh -p "$SSH_PORT" -M 0 -N $REMOTE_OPTS ${VPS_USER}@${VPS_HOST} &
echo "$!" > "/tmp/vps_tunnel_${DEVICE_IP_SUFFIX}-$!.pid"
