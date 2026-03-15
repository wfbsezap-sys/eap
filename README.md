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
-  **Auto-restart loop:** keeps EarnApp running continuously with exponential backoff
-  **Works on Linux and ARM devices** (Raspberry Pi, cloud servers)
-  **Container camouflage:** hides Docker environment from EarnApp detection
-  **Graceful shutdown:** proper signal handling via tini init

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

### Docker Run
```bash
docker run -d \
  --name earnapp \
  -e EARNAPP_UUID="YOUR_EARNAPP_UUID" \
  -v /etc/earnapp:/etc/earnapp \
  haomomoa/earnapp:latest
```

### Docker Compose
```yaml
services:
  earnapp:
    container_name: earnapp
    image: haomomoa/earnapp
    environment:
      - EARNAPP_UUID=<YOUR_EARNAPP_UUID>
    volumes:
      - /etc/earnapp:/etc/earnapp
    restart: always
```

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `EARNAPP_UUID` | Yes | Your EarnApp device UUID (`sdk-node-...`) |
| `DEBUG_MODE` | No | Set to `1` to launch a shell instead of EarnApp |

### Logs

View logs in real-time:
```bash
docker logs -f earnapp
```
Sample output:
```
[INFO] Starting EarnApp...
- Registering Device...
✔ Registered
✔ EarnApp is active (making money in the background)
```

### Notes

- The container fakes hostnamectl, lsb_release, machine-id, and spawns dummy processes so EarnApp runs properly in a minimal Docker environment.
- The entrypoint keeps EarnApp running and will automatically retry with exponential backoff if it crashes.
- Uses tini as PID 1 for proper zombie process reaping and signal handling.
