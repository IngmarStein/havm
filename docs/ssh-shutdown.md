---
layout: default
title: SSH & Shutdown
---

<div class="doc-page" markdown="1">

<div class="doc-nav">
  <a href="{{ site.baseurl }}/">← Home</a>
  <a href="getting-started.html">Getting Started</a>
  <a href="commands.html">Commands</a>
  <a href="configuration.html">Configuration</a>
  <a href="usb-accessories.html">USB Accessories</a>
  <a href="metrics.html">Metrics</a>
  <a href="building.html">Building</a>
</div>

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

<div class="note">
ACPI <code>requestStop()</code> is not used — HA OS on aarch64 uses PSCI
and ignores ACPI power button events.
</div>

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

<div class="warning">
The token is a secret. Keep your <code>config.yml</code> permissions
restrictive (<code>chmod 600 ~/.config/havm/config.yml</code>).
</div>

### Guest IP detection

`havm` discovers the guest IP by parsing `/var/db/dhcpd_leases` and matching
the VM's MAC address — instant and reliable, no ping or ARP scanning needed.

If you set a static IP or mDNS hostname in the config, that takes precedence:

```yaml
network:
  hostname: "homeassistant.local"
```

## Graceful Restart

Send `SIGHUP` to trigger a clean shutdown and restart. launchd / Homebrew
`keep_alive` will restart the process automatically:

```bash
kill -HUP $(cat ~/Library/Application\ Support/havm/vm/havm.pid)
```

This runs the full shutdown chain (REST API → SSH → force-stop) before
exiting. Useful after changing config settings that require a restart
(CPU, memory, disk size, network, USB).

[token]: https://www.home-assistant.io/docs/authentication/#your-account-profile

</div>
