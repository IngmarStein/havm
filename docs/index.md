---
layout: default
title: Home
---

<!-- ── Hero ───────────────────────────────────────────────────── -->
<section class="hero">
  <div class="hero-icon">🏠</div>
  <h1>havm</h1>
  <p class="hero-tagline">
    Zero-config CLI for running Home&nbsp;Assistant&nbsp;OS on Apple&nbsp;Silicon
    using the native Virtualization framework. One command from download to boot.
  </p>

  <div class="hero-badges">
    <img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT">
    <img src="https://img.shields.io/badge/Swift-6.4-orange?logo=swift&logoColor=white" alt="Swift 6.4">
    <img src="https://img.shields.io/badge/Apple-Virtualization%20Framework-blue?logo=apple&logoColor=white" alt="Apple Virtualization">
    <img src="https://img.shields.io/badge/macOS-27%2B-lightgrey?logo=apple&logoColor=white" alt="macOS 27+">
    <img src="https://img.shields.io/badge/%E2%99%A5-Sponsor-EC4899?logo=githubsponsors&logoColor=white" alt="Sponsor">
  </div>

  <div class="cta-group">
    <a href="#get-it" class="btn btn-primary">
      <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.64 7.64 0 0 1 4 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>
      Homebrew Install
    </a>
    <a href="https://github.com/IngmarStein/havm" class="btn btn-secondary">
      <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.64 7.64 0 0 1 4 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>
      Source on GitHub
    </a>
  </div>
</section>

<!-- ── What It Does ──────────────────────────────────────────── -->
<section>
  <div class="container">
    <span class="section-label">What it does</span>
    <h2>Your smart home, one command away</h2>

    <div class="feature-grid">
      <div class="feature-card">
        <div class="icon">⚡</div>
        <h3>Zero setup</h3>
        <p>Downloads and prepares HA OS automatically on first run. No Shortcuts, AppleScript, or manual launchd plists.</p>
      </div>
      <div class="feature-card">
        <div class="icon">🔄</div>
        <h3>Starts at login</h3>
        <p>Designed for headless operation as a launchd service. Fire-and-forget: your smart home boots with your Mac.</p>
      </div>
      <div class="feature-card">
        <div class="icon">💾</div>
        <h3>Persistent</h3>
        <p>All HA OS data — configs, add-ons, history — lives on a raw disk image. NVRAM and MAC address survive reboots.</p>
      </div>
      <div class="feature-card">
        <div class="icon">🔌</div>
        <h3>USB accessories</h3>
        <p>Attach coordinators via the menu bar item. Hot-plug, no restart needed.</p>
      </div>
      <div class="feature-card">
        <div class="icon">🔑</div>
        <h3>SSH key import</h3>
        <p>Virtual CONFIG disk imports your public key for root SSH on port 22222 — HA OS picks it up automatically.</p>
      </div>
      <div class="feature-card">
        <div class="icon">⏻</div>
        <h3>Graceful shutdown</h3>
        <p>REST API → SSH → force-stop fallback on SIGTERM. Three methods before pulling the plug.</p>
      </div>
      <div class="feature-card">
        <div class="icon">📊</div>
        <h3>Prometheus metrics</h3>
        <p>Built-in HTTP endpoint for monitoring VM state and USB accessories. Grafana-ready.</p>
      </div>
      <div class="feature-card">
        <div class="icon">📦</div>
        <h3>Self-contained</h3>
        <p>No Homebrew at runtime, no Python, no shell scripts. A single ~2.1 MB binary with zero external dependencies.</p>
      </div>
    </div>
  </div>
</section>

<!-- ── How It Works ──────────────────────────────────────────── -->
<section class="alt">
  <div class="container">
    <span class="section-label">How it works</span>
    <h2>First run does it all</h2>

    <div class="steps">
      <div class="step">
        <h3>Download</h3>
        <p>Fetches the latest stable HA OS release from GitHub. Cached for instant re-installs.</p>
      </div>
      <div class="step">
        <h3>Decompress</h3>
        <p>Built-in XZ decoder via libzma — no external tools, no Homebrew dependencies.</p>
      </div>
      <div class="step">
        <h3>Prepare disk</h3>
        <p>Copies and resizes the raw disk image. APFS sparse files keep it lean.</p>
      </div>
      <div class="step">
        <h3>Boot</h3>
        <p>UEFI boot from the GPT disk. No kernel extraction, no initrd. Just point at the image.</p>
      </div>
    </div>

    <div class="terminal">
      <div class="terminal-bar">
        <span class="terminal-dot"></span><span class="terminal-dot"></span><span class="terminal-dot"></span>
        <span class="terminal-title">Terminal — havm run</span>
      </div>
      <div class="terminal-body">
        <span class="prompt">$</span> <span class="cmd">brew install ingmarstein/havm/havm</span><br>
        <span class="out">==> Caveats</span><br>
        <span class="out">Downloads and sets up Home Assistant OS automatically on first run.</span><br>
        <span class="out">Data: /opt/homebrew/var/lib/havm/</span><br>
        <span class="out">Optional config: /opt/homebrew/etc/havm/config.yml</span><br>
        <span class="out">To start havm now and restart at login:</span><br>
        <span class="out">  brew services start havm</span><br>
        <span class="out">Or, if you don't want a background service you can just run:</span><br>
        <span class="out">  havm run</span><br>
        <span class="out">🍺 /opt/homebrew/Cellar/havm/0.1.4: 12 files, 2.2MB</span>
      </div>
    </div>

    <p>Then run it — havm handles the rest automatically:</p>

    <div class="terminal">
      <div class="terminal-bar">
        <span class="terminal-dot"></span><span class="terminal-dot"></span><span class="terminal-dot"></span>
        <span class="terminal-title">Terminal — havm run (first boot)</span>
      </div>
      <div class="terminal-body">
        <span class="prompt">$</span> <span class="cmd">havm run</span><br>
        <span class="out">Config loaded: CPU=4 Memory=4 GiB Network=nat</span><br>
        <span class="out">Starting HA OS setup...</span><br>
        <span class="out">Found HA OS 18.0: haos_generic-aarch64-18.0.img.xz</span><br>
        <span class="out">Resizing disk to 32 GiB...</span><br>
        <span class="out">Disk resized. HA OS will auto-expand partitions on first boot.</span><br>
        <span class="out">SSH CONFIG disk created</span><br>
        <span class="out">✅ HA OS setup complete.</span><br>
        <span class="out">CPU: 4, Memory: 4 GiB</span><br>
        <span class="out">Network: NAT</span><br>
        <span class="out">Starting VM...</span><br>
        <span class="out">VM started successfully</span><br>
        <span class="out">VM is running. Press Ctrl+C to stop.</span><br>
        <span class="out">Guest reachable at 192.168.64.33</span><br>
        <span class="accent">  Web: http://192.168.64.33:8123</span><br>
        <span class="accent">  SSH: ssh root@192.168.64.33 -p 22222</span>
      </div>
    </div>
  </div>
</section>

<!-- ── VM Hardware ────────────────────────────────────────────── -->
<section>
  <div class="container">
    <span class="section-label">Under the hood</span>
    <h2>VM hardware</h2>

    <table class="spec-table">
      <thead>
        <tr><th>Component</th><th>Choice</th><th>Why</th></tr>
      </thead>
      <tbody>
        <tr><td>Boot</td><td>UEFI (<code>VZEFIBootLoader</code>)</td><td>Boots directly from the GPT disk image</td></tr>
        <tr><td>CPU</td><td>4 cores (configurable)</td><td>Sufficient for HA OS + add-ons</td></tr>
        <tr><td>Memory</td><td>4 GiB (configurable)</td><td>Balloon lets macOS reclaim idle guest memory</td></tr>
        <tr><td>Entropy</td><td>VirtIO entropy device</td><td>Random numbers for guest crypto and ASLR</td></tr>
        <tr><td>Disk</td><td>32 GiB raw image, VirtIO block</td><td>APFS sparse on disk (~6 GiB used after first boot)</td></tr>
        <tr><td>Network</td><td>NAT with stable MAC</td><td>Works out of the box, no extra setup</td></tr>
        <tr><td>CONFIG disk</td><td>USB mass storage (XHCI)</td><td>HA OS imports SSH keys from USB, not VirtIO</td></tr>
        <tr><td>NVRAM</td><td>Persisted EFI variable store</td><td>GRUB boot state survives reboots</td></tr>
        <tr><td>Platform</td><td><code>VZGenericPlatformConfiguration</code></td><td>Stable machine ID → consistent MAC</td></tr>
      </tbody>
    </table>
  </div>
</section>

<!-- ── Open by Default ────────────────────────────────────────── -->
<section class="alt">
  <div class="container">
    <span class="section-label">Open by default</span>
    <h2>Trust &amp; transparency</h2>

    <div class="trust-strip">
      <div class="trust-item"><span class="check">✓</span> MIT license</div>
      <div class="trust-item"><span class="check">✓</span> Full source on GitHub</div>
      <div class="trust-item"><span class="check">✓</span> No telemetry, no accounts</div>
      <div class="trust-item"><span class="check">✓</span> No external runtime dependencies</div>
      <div class="trust-item"><span class="check">✓</span> No surprise network calls</div>
      <div class="trust-item"><span class="check">✓</span> Single self-contained binary</div>
    </div>
  </div>
</section>

<!-- ── Get It ─────────────────────────────────────────────────── -->
<section id="get-it">
  <div class="container">
    <span class="section-label">Get it</span>
    <h2>Install</h2>

    <h3>Homebrew (recommended)</h3>
    <div class="terminal">
      <div class="terminal-bar">
        <span class="terminal-dot"></span><span class="terminal-dot"></span><span class="terminal-dot"></span>
        <span class="terminal-title">Terminal</span>
      </div>
      <div class="terminal-body">
        <span class="prompt">$</span> <span class="cmd">brew install ingmarstein/havm/havm</span><br>
        <span class="prompt">$</span> <span class="cmd">havm run</span>
      </div>
    </div>

    <p>Or run as a background service that starts at login:</p>
    <div class="terminal">
      <div class="terminal-bar">
        <span class="terminal-dot"></span><span class="terminal-dot"></span><span class="terminal-dot"></span>
        <span class="terminal-title">Terminal</span>
      </div>
      <div class="terminal-body">
        <span class="prompt">$</span> <span class="cmd">brew services start havm</span>
      </div>
    </div>

    <br>
    <h3>Build from source</h3>
    <div class="terminal">
      <div class="terminal-bar">
        <span class="terminal-dot"></span><span class="terminal-dot"></span><span class="terminal-dot"></span>
        <span class="terminal-title">Terminal</span>
      </div>
      <div class="terminal-body">
        <span class="prompt">$</span> <span class="cmd">git clone https://github.com/IngmarStein/havm.git && cd havm</span><br>
        <span class="prompt">$</span> <span class="cmd">cp resources/build.xcconfig.example resources/build.xcconfig</span><br>
        <span class="prompt">$</span> <span class="cmd">./scripts/build.sh release</span><br>
        <span class="prompt">$</span> <span class="cmd">.build/release/havm run</span>
      </div>
    </div>
  </div>
</section>

<!-- ── Data Layout ─────────────────────────────────────────────── -->
<section>
  <div class="container">
    <span class="section-label">Where things go</span>
    <h2>Data layout</h2>

    <table class="spec-table">
      <thead>
        <tr><th></th><th>Foreground</th><th>Service</th></tr>
      </thead>
      <tbody>
        <tr><td>VM data</td><td><code>~/Library/Application Support/havm/vm/</code></td><td><code>/opt/homebrew/var/lib/havm/</code></td></tr>
        <tr><td>Config (optional)</td><td><code>~/.config/havm/config.yml</code></td><td><code>/opt/homebrew/etc/havm/config.yml</code></td></tr>
        <tr><td>Downloads cache</td><td colspan="2"><code>~/Library/Caches/havm/</code></td></tr>
      </tbody>
    </table>
  </div>
</section>

<!-- ── Config Preview ─────────────────────────────────────────── -->
<section class="alt">
  <div class="container">
    <span class="section-label">Optional</span>
    <h2>Configuration</h2>
    <p>Everything works with zero config. Tweak <code>~/.config/havm/config.yml</code> if you want:</p>

    <div class="terminal">
      <div class="terminal-bar">
        <span class="terminal-dot"></span><span class="terminal-dot"></span><span class="terminal-dot"></span>
        <span class="terminal-title">~/.config/havm/config.yml</span>
      </div>
      <div class="terminal-body">
<pre>
vm:
  cpu_count: 4
  memory_size: "4 GiB"
  disk_size: "32 GiB"
network:
  type: nat
haos:
  release_channel: stable
ssh:
  authorized_keys: "~/.ssh/id_ed25519.pub"
metrics:
  enabled: true
</pre>
      </div>
    </div>

    <p style="margin-top: 1.25rem;">
      <a href="configuration.html">Full configuration reference</a> &rarr;
    </p>
  </div>
</section>

<!-- ── Next Steps ─────────────────────────────────────────────── -->
<section>
  <div class="container">
    <span class="section-label">Learn more</span>
    <h2>Documentation</h2>

    <div class="feature-grid">
      <a href="getting-started.html" class="feature-card" style="text-decoration: none;">
        <div class="icon">🚀</div>
        <h3>Getting Started</h3>
        <p>Prerequisites, installation, first-run walkthrough, and next steps.</p>
      </a>
      <a href="commands.html" class="feature-card" style="text-decoration: none;">
        <div class="icon">⌨️</div>
        <h3>Commands</h3>
        <p>CLI reference: <code>run</code>, <code>import-utm</code>, <code>cleanup</code>, <code>version</code>.</p>
      </a>
      <a href="configuration.html" class="feature-card" style="text-decoration: none;">
        <div class="icon">⚙️</div>
        <h3>Configuration</h3>
        <p>Full <code>config.yml</code> reference with every field explained.</p>
      </a>
      <a href="ssh-shutdown.html" class="feature-card" style="text-decoration: none;">
        <div class="icon">🔐</div>
        <h3>SSH &amp; Shutdown</h3>
        <p>Debug SSH setup, graceful shutdown chain, guest IP detection.</p>
      </a>
      <a href="usb-accessories.html" class="feature-card" style="text-decoration: none;">
        <div class="icon">🔌</div>
        <h3>USB Accessories</h3>
        <p>Hot-plug coordinators via the menu bar. Entitlements and troubleshooting.</p>
      </a>
      <a href="metrics.html" class="feature-card" style="text-decoration: none;">
        <div class="icon">📊</div>
        <h3>Metrics</h3>
        <p>Prometheus endpoint, Grafana dashboard examples, scrape configs.</p>
      </a>
      <a href="building.html" class="feature-card" style="text-decoration: none;">
        <div class="icon">🛠️</div>
        <h3>Building</h3>
        <p>Build from source, entitlement tiers, architecture overview.</p>
      </a>
      <a href="https://github.com/IngmarStein/havm/blob/main/CONTRIBUTING.md" class="feature-card" style="text-decoration: none;">
        <div class="icon">🤝</div>
        <h3>Contributing</h3>
        <p>Development workflow, code style, PR checklist, finding issues to work on.</p>
      </a>
    </div>
  </div>
</section>
