# Template for the Tiwari1999/homebrew-tap repo; scripts/release.sh fills version and sha256.
cask "agent-island" do
  version "0.5.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Tiwari1999/Agent-Island/releases/download/v#{version}/AgentIsland-#{version}.dmg",
      verified: "github.com/Tiwari1999/Agent-Island/"
  name "AgentIsland"
  desc "Notch app that shows every running AI coding agent"
  homepage "https://agentisland.in/"

  livecheck do
    url "https://agentisland.in/appcast.xml"
    strategy :sparkle
  end

  # Sparkle updates it in place, so brew must not treat a newer bundle as drift.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "AgentIsland.app"

  # Hooks stay on uninstall: brew runs this on every reinstall and --greedy upgrade too, and with
  # no island running each hook exits at once. --zap is the one that unregisters them.
  uninstall quit: "io.github.tiwari1999.agentisland"

  zap script: {
        executable:   "/usr/bin/python3",
        args:         [File.expand_path("~/Library/Application Support/AgentIsland/uninstall-hooks.py")],
        must_succeed: false,
      },
      trash:  [
    "~/Library/Application Support/AgentIsland",
    "~/Library/Caches/io.github.tiwari1999.agentisland",
    "~/Library/HTTPStorages/io.github.tiwari1999.agentisland",
    "~/Library/Preferences/io.github.tiwari1999.agentisland.plist",
  ]
end
