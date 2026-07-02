---
layout: default
title: Metrics
---

<div class="doc-page" markdown="1">

<div class="doc-nav">
  <a href="{{ site.baseurl }}/">← Home</a>
  <a href="getting-started.html">Getting Started</a>
  <a href="commands.html">Commands</a>
  <a href="configuration.html">Configuration</a>
  <a href="ssh-shutdown.html">SSH & Shutdown</a>
  <a href="usb-accessories.html">USB Accessories</a>
  <a href="building.html">Building</a>
</div>

# Prometheus Metrics

`havm` can expose Prometheus metrics on an HTTP endpoint for monitoring
with Prometheus or any compatible scraper. Enable it in the config:

```yaml
metrics:
  enabled: true
```

The server listens on `127.0.0.1:9210` by default and serves two endpoints:

| Endpoint | Description |
|----------|-------------|
| `GET /metrics` | Prometheus text format metrics |
| `GET /health` | Liveness check — returns `200 OK` |

## Available Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `havm_vm_state` | gauge | `state` | VM state (running, stopped, paused, starting, …) |
| `havm_usb_accessories` | gauge | — | Number of connected USB accessories |
| `havm_disk_usage_bytes` | gauge | `disk`, `type` | Disk image size: `type=logical` (configured size) or `allocated` (actual APFS allocation) |

Prometheus also adds its synthetic `up` metric — `1` when the scrape
succeeds, `0` when `havm` is unreachable.

## Prometheus Scrape Config

```yaml
scrape_configs:
  - job_name: 'havm'
    static_configs:
      - targets: ['localhost:9210']
```

## LAN Access

The server binds to `127.0.0.1` by default. To allow LAN access (e.g.,
a dedicated Prometheus host), bind to all interfaces:

```yaml
metrics:
  enabled: true
  prometheus:
    host: "0.0.0.0"
```

## Custom Port

```yaml
metrics:
  enabled: true
  prometheus:
    port: 8080
```

## Example: Grafana Dashboard

With Prometheus scraping `havm`, you can build a simple Grafana dashboard:

- **Stat panel** — `havm_vm_state` to show current VM status
- **Time series** — `havm_disk_usage_bytes` to track main disk allocation vs logical size
- **Alert rule** — `havm_disk_usage_bytes{type="allocated"} / havm_disk_usage_bytes{type="logical"} > 0.85` warns when sparse allocation approaches capacity

The `up` metric from Prometheus itself acts as a heartbeat — if `up == 0`,
`havm` is unreachable and the VM may be down.

## Configuration Reference

```yaml
metrics:
  enabled: true           # default: false
  type: prometheus        # prometheus (default) — extensibility point for OTLP
  prometheus:
    port: 9210            # default: 9210
    host: "127.0.0.1"     # default: "127.0.0.1"
```

<div class="note">
The <code>type</code> field is an extensibility point — only
<code>prometheus</code> is supported today, but the field exists for
future OTLP or other formats.
</div>

</div>
