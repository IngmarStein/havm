---
title: Metrics
nav_order: 7
---

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
- **Time series** — `havm_usb_accessories` to track accessory count over time
- **Alert rule** — fire when `havm_vm_state != 1` (VM not running) for
  more than 2 minutes

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

{: .note }
The `type` field is an extensibility point — only `prometheus` is
supported today, but the field exists for future OTLP or other formats.

## Entitlements

All entitlement tiers include `com.apple.security.network.server`, so
metrics work regardless of your account type.
