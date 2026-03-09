# EarnApp Docker Container

[![Docker Pulls](https://img.shields.io/docker/pulls/madereddy/earnapp)](https://hub.docker.com/r/madereddy/earnapp)

EarnApp container with **Debian slim**, multi-architecture support, and persistent configuration.

Use my referral link when creating an EarnApp account:
[Sign up here](https://earnapp.com/i/s7bb5Y5Z)

---

## Features

-  **Multi-arch support:** `amd64`, `arm64`, `arm/v7`
-  **Slim image:** ~50–60MB runtime
-  **Persistent configuration:** `/etc/earnapp`
-  **No runtime downloads:** EarnApp binary is baked into the image
-  **Auto-restart loop:** keeps EarnApp running continuously
-  **Works on Linux and ARM devices** (Raspberry Pi, cloud servers)
-  **SOCKS5 proxy support:** route traffic through a SOCKS5 proxy via redsocks + iptables
-  **VLESS proxy support:** use a VLESS share link directly (xray-core built in)
-  **Container camouflage:** hides Docker environment from EarnApp detection

---

## How to Get UUID
1.  The UUID is 32 characters long with lowercase alphabet and numbers. You can either create this by yourself or via this command:
    ```bash
    echo -n sdk-node- && head -c 1024 /dev/urandom | md5sum | tr -d ' -'
    ```

    *Example output* </br>
    *sdk-node-0123456789abcdeffedcba9876543210*

2.  Before registering your device, ensure that you pass the UUID into the container and start it first. Then proceed to register your device using the url:
    ```
    https://earnapp.com/r/UUID
    ```
    *Example url* </br>
    *`https://earnapp.com/r/sdk-node-0123456789abcdeffedcba9876543210`*

## Running the Container

### Basic
```bash
docker run -d \
  --name earnapp \
  -e EARNAPP_UUID="YOUR_EARNAPP_UUID" \
  -v /etc/earnapp:/etc/earnapp \
  madereddy/earnapp:latest
```

### With VLESS Proxy
```bash
docker run -d \
  --name earnapp \
  --cap-add=NET_ADMIN \
  -e EARNAPP_UUID="YOUR_EARNAPP_UUID" \
  -e VLESS_URL="vless://uuid@host:port?type=tcp&security=reality&sni=example.com&fp=chrome&pbk=...&sid=..." \
  --hostname debian-earnapp \
  madereddy/earnapp:latest
```

### With SOCKS5 Proxy
```bash
docker run -d \
  --name earnapp \
  --cap-add=NET_ADMIN \
  -e EARNAPP_UUID="YOUR_EARNAPP_UUID" \
  -e SOCKS5_PROXY="socks5://user:pass@host:port" \
  --hostname debian-earnapp \
  madereddy/earnapp:latest
```

> **Note:** `--cap-add=NET_ADMIN` is required for proxy modes (iptables).
> When both `VLESS_URL` and `SOCKS5_PROXY` are set, VLESS takes priority.

### Docker Compose Example
```yaml
services:
  earnapp:
    container_name: earnapp
    image: madereddy/earnapp
    cap_add:
      - NET_ADMIN
    hostname: debian-earnapp
    environment:
      - EARNAPP_UUID=<YOUR_EARNAPP_UUID>
      - VLESS_URL=vless://uuid@host:port?type=tcp&security=reality&...
    restart: always
```

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `EARNAPP_UUID` | Yes | Your EarnApp device UUID (`sdk-node-...`) |
| `VLESS_URL` | No | VLESS share link (`vless://...`) |
| `SOCKS5_PROXY` | No | SOCKS5 proxy (`socks5://[user:pass@]host:port`) |
| `DEBUG_MODE` | No | Set to `1` to launch a shell instead of EarnApp |

### Supported VLESS Parameters

| Parameter | Values | Description |
|---|---|---|
| `type` | `tcp`, `ws` | Transport protocol |
| `security` | `none`, `tls`, `reality` | Security layer |
| `sni` | hostname | TLS/Reality server name |
| `fp` | `chrome`, `firefox`, etc. | Browser fingerprint (default: `chrome`) |
| `flow` | e.g. `xtls-rprx-vision` | XTLS flow control |
| `pbk` | string | Reality public key |
| `sid` | string | Reality short ID |
| `path` | URL path | WebSocket path |
| `encryption` | `none` | Encryption method (default: `none`) |

### Proxy Architecture

```
EarnApp → iptables → redsocks (:12345) → xray (:10808) → VLESS server → internet
```

When `VLESS_URL` is set, xray-core converts the VLESS protocol into a local SOCKS5 proxy, which is then used by redsocks + iptables for transparent proxying.

### Logs

View logs in real-time:
```bash
docker logs -f earnapp
```
Sample output:
```
[INFO] VLESS proxy configured, setting up xray...
[INFO] xray started (VLESS -> 1.2.3.4:443)
[INFO] SOCKS5 proxy configured, setting up redsocks...
[INFO] redsocks started (proxy: 127.0.0.1:10808)
[INFO] iptables rules configured, all TCP traffic routed through SOCKS5 proxy
[INFO] Starting EarnApp...
- Registering Device...
✔ Registered
✔ EarnApp is active (making money in the background)
```

### Notes

- The container fakes hostnamectl, lsb_release, machine-id, and spawns dummy processes so EarnApp runs properly in a minimal Docker environment.
- The entrypoint keeps EarnApp running and will automatically retry with exponential backoff if it crashes.
- xray-core binary is included in the image (auto-downloads latest version during build).
