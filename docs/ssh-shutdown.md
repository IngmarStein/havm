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

On SIGTERM or Ctrl+C, `havm` tries these shutdown methods in order:

1. **HA REST API** — `POST <ha.url>/api/services/hassio/host_shutdown`, where the default
   address is probed: `http://<ip>` on HAOS 2026.8+, `http://<ip>:8123` before it
   (requires a [long-lived access token][token] in `ha.api_token`)
2. **Debug SSH (port 22222)** — `ssh root@<ip> -p 22222 shutdown -h now`
   (requires `ssh.authorized_keys` for CONFIG disk import)
3. **SSH add-on (port 22)** — `ssh root@<ip> -p 22 ha host shutdown`
   (requires the SSH add-on installed in HA)
4. **Force-stop** — if all above fail, the VM is stopped immediately

A method that fails falls through to the next one. If the REST API request is
sent but no response comes back, `havm` treats the guest as already halting and
waits for it rather than moving on to SSH.

`shutdown.timeout_seconds` is **one budget for the whole chain, not a
timeout per method**. Every request attempt and every wait for the guest to
halt is drawn from the same deadline, so falling through to the next method
does not restart the clock. When the budget runs out the VM is force-stopped —
even if a method accepted the shutdown request and the guest is still halting
cleanly. Raise it if your guest regularly needs longer than 90 seconds.

<div class="note">
ACPI <code>requestStop()</code> is not used — HA OS on aarch64 uses PSCI
and ignores ACPI power button events.
</div>

### Configuration

```yaml
ha:
  api_token: "eyJ..."     # HA long-lived access token
  url: "https://homeassistant.local:443"  # default: probed (see above)

shutdown:
  timeout_seconds: 90     # budget for the whole shutdown chain (default: 90)
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

In bridge mode (the default) `havm` reaches the guest by its mDNS name —
`network.hostname`, defaulting to `homeassistant.local`. In NAT mode there is no
name, so it parses `/var/db/dhcpd_leases` and matches the VM's MAC address.

Set a static IP or a unique name to override the default:

```yaml
network:
  hostname: "192.168.1.42"
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
