class Kite < Formula
  desc "Remote controller for AI coding assistants"
  homepage "https://github.com/AnerYu/kite"
  version "0.1.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/AnerYu/kite/releases/download/v#{version}/kite-darwin-arm64.tar.gz"
      sha256 "PLACEHOLDER_SHA256"
    end
    on_intel do
      url "https://github.com/AnerYu/kite/releases/download/v#{version}/kite-darwin-amd64.tar.gz"
      sha256 "PLACEHOLDER_SHA256"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/AnerYu/kite/releases/download/v#{version}/kite-linux-arm64.tar.gz"
      sha256 "PLACEHOLDER_SHA256"
    end
    on_intel do
      url "https://github.com/AnerYu/kite/releases/download/v#{version}/kite-linux-amd64.tar.gz"
      sha256 "PLACEHOLDER_SHA256"
    end
  end

  def install
    bin.install "kite"
  end

  test do
    assert_match "kite", shell_output("#{bin}/kite help")
  end
end
