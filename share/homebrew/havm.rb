class Havm < Formula
  desc "Zero-config Home Assistant OS VM runner for Apple Silicon"
  homepage "https://github.com/homebrew/havm"
  url "https://github.com/homebrew/havm/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_ACTUAL_SHA256"
  license "MIT"
  head "https://github.com/homebrew/havm.git", branch: "main"

  # macOS 27 Golden Gate required at runtime.
  # Homebrew may not yet have a :golden_gate symbol; adjust when available.
  depends_on macos: :sequoia  # minimum for formula; actual requirement is macOS 27
  depends_on arch: :arm64
  depends_on xcode: ["17.0", :build]

  uses_from_macos "swift"

  def install
    system "swift", "build", "--disable-sandbox",
           "--configuration", "release",
           "--product", "havm"
    bin.install ".build/release/havm"

    # Install config example
    (etc/"havm").mkpath
    (share/"havm/examples").install Dir["share/examples/*"]
  end

  service do
    run [opt_bin/"havm", "run"]
    keep_alive true
    run_type :immediate
    working_dir var/"lib/havm"
    log_path var/"log/havm.log"
    error_log_path var/"log/havm-error.log"
    environment_variables PATH: std_service_path_env
  end

  def caveats
    <<~EOS
      havm will automatically download and set up Home Assistant OS on first run.

      Quick start:
        havm run      # Start the VM — auto-downloads HA OS on first run

      Start as a background service:
        brew services start havm

      Optional config: ~/.config/havm/config.yml
      Data directory:  ~/.local/share/havm/

      Requires macOS 27 (Golden Gate) or later with Apple Silicon.
    EOS
  end

  test do
    system "#{bin}/havm", "version"
  end
end
