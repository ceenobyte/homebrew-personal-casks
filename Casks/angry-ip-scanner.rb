cask "angry-ip-scanner" do
  arch arm: "Arm64", intel: "X86"

    version "3.12.1"
    sha256 arm:   "4dfe0ffd15b11d61aeaec12b293e3c2ce827c98485476eaa2ea082722f612ed2",
      intel: "e5d70bbf6fe935cacf99e1c2693363de65cece491852cd393714fa6b89daf282"

  download_name = if version >= "3.12.0"
    "ipscan-#{version}-mac#{arch}"
  else
    "ipscan-mac#{arch}-#{version}"
  end
  url "https://github.com/angryip/ipscan/releases/download/#{version}/#{download_name}.zip"
  name "Angry IP Scanner"
  desc "Network scanner"
  homepage "https://angryip.org/"

  # disable! date: "2026-09-01", because: :fails_gatekeeper_check

  depends_on :macos

  app "Angry IP Scanner.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/Angry IP Scanner.app"],
        sudo: false
  end

  zap :not_required
end
