# 🔌 vps_tunnel.sh

A Bash script that automatically discovers open TCP ports on your local machine and tunnels them securely to a VPS using `autossh`. Ideal for **homelab** setups with limited access due to CGNAT, where incoming connections from the VPS side are impossible.

---

## 🚀 Features

- 🔍 **Auto-discovers** running local TCP services (via `ss`)
- 📤 **Securely forwards** all open ports to your VPS over SSH with autossh
- 🔁 **Persistent tunnels** using autossh (auto-reconnect)
- ⚙️ **Exclusion config** lets you skip noisy or sensitive ports
- 🧠 **Interactive prompts** for exclusion and saving config
- 💾 Writes a `PID` file to `/tmp/` for easy tunnel tracking

---

## 📦 Requirements

- `bash`
- `autossh`
- `ss` (usually part of `iproute2`)
- `awk`, `sed`, `sort`, `uniq`

---

## 🧰 Installation

Clone the repo and make the script executable:

```bash
git clone https://github.com/yourusername/vps_tunnel.git
cd vps_tunnel
chmod +x vps_tunnel.sh
```

---

## ⚙️ Usage

```bash
./vps_tunnel.sh [options]
```

### Options:

| Flag         | Description                                | Default                       |
|--------------|--------------------------------------------|-------------------------------|
| `-u USER`    | SSH username for VPS                       | `root`                        |
| `-h HOST`    | VPS hostname or IP                         | `gate.lab`                    |
| `-P PORT`    | SSH port on VPS                            | `22`                          |
| `-d IP`      | Device IP suffix (127.0.0.X)               | `58`                          |
| `-c CONFIG`  | Path to excluded ports config              | `~/.config/vps_tunnel-xport.conf` |
| `-?`         | Show help                                  | —                             |

### Example:

```bash
./vps_tunnel.sh -u root -h 146.234.156.34 -P 34898 -d 59 -c ~/.config/vps_exclude.conf
```

---

## 🧠 How It Works

1. Scans for open TCP ports and the processes using them via `ss`.
2. Prompts you to exclude any of them.
3. Builds reverse SSH tunnels like:
   ```
   -R 127.0.0.59:80:127.0.0.1:80
   ```
4. Launches `autossh` to maintain the tunnel.
5. Writes a PID file to `/tmp/vps_tunnel_59.pid`.

---

## 📂 Exclusion Config

If you run the script multiple times, it remembers which ports you excluded last time using a config file:

```
~/.config/vps_tunnel-xport.conf
```

You can edit this manually or via the script's interactive prompt.

---

## 🧪 Monitoring

The actual SSH tunnel can be inspected via:

```bash
ps aux | grep autossh
cat /tmp/vps_tunnel_58.pid
```

Or test a forwarded port from the VPS side:

```bash
curl http://127.0.0.58:8080
```

---

## 🔐 Security Considerations

- Ensure your VPS user is restricted (e.g., key-only login, limited shell if needed).
- Consider firewalling or service-authenticating your forwarded ports on the VPS.


`AI Generated readme `
