---
title: SSH & Shutdown
nav_order: 5
---

# SSH Access & Graceful Shutdown

## SSH Access

Add your public key to the config and HA OS will import it on boot, enabling
root SSH access on port 22222:

```yaml
ssh:
  authorized_keys: "~/.ssh/id_ed25519.pub"
```

`havm` creates a small MBR + FAT16 disk image with volume label `CONFIG` and
an `authorized_keys` file. HA OS auto-imports it on boot and starts `dropbear`
on port 22222. Without this file, HA OS disables the debug SSH server.

```bash
ssh root@<guest-ip> -p 22222
```

For the regular SSH add-on (Terminal & SSH or Advanced SSH & Web Terminal),
install the add-on via the HA web UI — it listens on port 22.

## Graceful Shutdown

On SIGTERM or Ctrl+C, `havm` tries these shutdown methods in order, falling
through to the next if one fails:

1. **HA REST API** — `POST http://<ip>:8123/api/services/hassio/host_shutdown`
   (requires a [long-lived access token][token] in `ha.api_token`)
2. **Debug SSH (port 22222)** — `ssh root@<ip> -p 22222 shutdown -h now`
   (requires `ssh.authorized_keys` for CONFIG disk import)
3. **SSH add-on (port 22)** — `ssh root@<ip> -p 22 ha host shutdown`
   (requires the SSH add-on installed in HA)
4. **Force-stop** — if all above fail, the VM is stopped immediately

{: .note }
ACPI `requestStop()` is not used — HA OS on aarch64 uses PSCI and ignores
ACPI power button events.

### Configuration

```yaml
ha:
  api_token: "eyJ..."     # HA long-lived access token
  url: "https://homeassistant.local:443"  # default: http://<ip>:8123

shutdown:
  timeout_seconds: 30     # max wait for guest to halt (default: 30)
```

### How to get an API token

1. In Home Assistant, go to your profile (click your username)
2. Scroll to **Long-Lived Access Tokens**
3. Click **Create Token**, give it a name (e.g., "havm shutdown"), and copy it
4. Add it to your config as `ha.api_token`

{: .warning }
The token is a secret. Keep your `config.yml` permissions restrictive
(`chmod 600 ~/.config/havm/config.yml`).

### Guest IP detection

`havm` discovers the guest IP by parsing `/var/db/dhcpd_leases` and matching
the VM's MAC address — instant and reliable, no ping or ARP scanning needed.

If you set a static IP or mDNS hostname in the config, that takes precedence:

```yaml
network:
  hostname: "homeassistant.local"
```

[token]: https://www.home-assistant.io/docs/authentication/#your-account-profile
