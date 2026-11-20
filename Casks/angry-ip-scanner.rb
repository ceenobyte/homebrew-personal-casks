cask "angry-ip-scanner" do
  arch arm: "Arm64", intel: "X86"

  version "3.12.2"
  sha256 arm:   "d27ba31ed018fdb2230f03b57d0a4bc568d31bd6da694d8150c58fcb9862839b",
         intel: "7b348837ad76ccf035360009f24b77e33bc2d80e1324b5084df946c1106c5ab9"

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
