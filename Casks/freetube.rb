cask "freetube" do
  arch arm: "arm64", intel: "x64"

    version "0.26.0"
    sha256 arm:   "16b49e40297e35806aec173d2f2a9f2bf85e1e377207d40ac365c59e7a73a8b2",
      intel: "2e9343898c6a33acf7e48f81c24d97c7fe45cb7c942ab6e27c509118a03b18cb"

  url "https://github.com/FreeTubeApp/FreeTube/releases/download/v#{version}-beta/freetube-#{version}-beta-mac-#{arch}.dmg"
  name "FreeTube"
  desc "YouTube player focusing on privacy"
  homepage "https://freetubeapp.io/"

  livecheck do
    url :url
    regex(/^v?(\d+(?:\.\d+)+)/i)
  end

  # disable! date: "2026-09-01", because: :fails_gatekeeper_check

  depends_on macos: :sequoia

  app "FreeTube.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/FreeTube.app"],
        sudo: false
  end

  uninstall quit: "io.freetubeapp.freetube"

  zap trash: [
    "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/io.freetubeapp.freetube.sfl*",
    "~/Library/Application Support/FreeTube",
    "~/Library/Preferences/io.freetubeapp.freetube.plist",
    "~/Library/Saved Application State/io.freetubeapp.freetube.savedState",
  ]
end
