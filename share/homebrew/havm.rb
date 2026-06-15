class Havm < Formula
  desc "Zero-config Home Assistant OS VM runner for Apple Silicon"
  homepage "https://github.com/IngmarStein/havm"
  url "https://github.com/IngmarStein/havm/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_ACTUAL_SHA256"
  license "MIT"
  head "https://github.com/IngmarStein/havm.git", branch: "main"

  depends_on macos: :golden_gate  # macOS 27+ with Apple Silicon
  depends_on arch: :arm64
  depends_on xcode: ["17.0", :build]
  uses_from_macos "swift"

  def install
    system "swift", "build", "--disable-sandbox",
           "--configuration", "release",
           "--product", "havm"
    bin.install ".build/release/havm"

    # Install example config to Homebrew's etc directory
    (etc/"havm").install "share/examples/config.yml" => "havm.yml"
  end

  service do
    run [opt_bin/"havm", "run", "--config", etc/"havm/havm.yml"]
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
        havm run                    # Start VM — auto-downloads HA OS on first run
        havm run -c #{etc}/havm/havm.yml  # Use the installed config

      Background service:
        brew services start havm    # Runs with #{etc}/havm/havm.yml

      User config: ~/.config/havm/config.yml
      Data:        ~/Library/Application Support/havm/

      Requires macOS 27 (Golden Gate) with Apple Silicon.
    EOS
  end

  test do
    system "#{bin}/havm", "version"
  end
end
