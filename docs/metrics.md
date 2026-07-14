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

The server listens on `::1:9210` (IPv6 loopback, dual-stack) by default and serves two endpoints:

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

The server binds to `::1` (both IPv4 and IPv6 loopback) by default. To allow LAN access (e.g.,
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

## Grafana Dashboard

An example Grafana dashboard is included in the repository at
[`grafana/dashboard.json`][dashboard]. Import it via Grafana's UI
(**Dashboards → New → Import**) or place it in a provisioned dashboard
directory.

<a href="https://github.com/IngmarStein/havm/blob/main/grafana/dashboard.json">
  <img src="https://raw.githubusercontent.com/IngmarStein/havm/refs/heads/main/grafana/dashboard.png"
       alt="Grafana dashboard preview" style="max-width:100%">
</a>

The dashboard covers:

| Panel | Type | Metric |
|-------|------|--------|
| VM Status | Stat | `havm_vm_state` |
| VM Status (History) | Time series | `havm_vm_state` |
| USB Devices | Stat | `havm_usb_accessories` |
| Disk (Logical) | Stat | `havm_disk_usage_bytes{type="logical"}` |
| Disk (Allocated) | Stat | `havm_disk_usage_bytes{type="allocated"}` |
| Usage (%) | Gauge | `allocated / logical * 100` |
| Disk (Unallocated) | Stat | `logical - allocated` |
| Storage Usage (History) | Time series | `havm_disk_usage_bytes` |

[dashboard]: https://github.com/IngmarStein/havm/blob/main/grafana/dashboard.json

## Configuration Reference

```yaml
metrics:
  enabled: true           # default: false
  type: prometheus        # prometheus (default) — extensibility point for OTLP
  prometheus:
    port: 9210            # default: 9210
    host: "::1"           # default: "::1"
```

<div class="note">
The <code>type</code> field is an extensibility point — only
<code>prometheus</code> is supported today, but the field exists for
future OTLP or other formats.
</div>

</div>
