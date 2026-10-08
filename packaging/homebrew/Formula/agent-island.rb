# Template for the Tiwari1999/homebrew-tap repo. Builds on the user's Mac, so the app is never
# quarantined and opens with no Gatekeeper prompt; no Apple Developer ID needed.
class AgentIsland < Formula
  desc "Every coding agent you run, in your MacBook notch"
  homepage "https://agentisland.in"
  url "https://github.com/Tiwari1999/Agent-Island.git", tag: "v0.5.12"
  license "MIT"
  head "https://github.com/Tiwari1999/Agent-Island.git", branch: "main"

  depends_on macos: :sonoma

  def install
    ENV["AGENTISLAND_SWIFT_FLAGS"] = "--disable-sandbox"
    system "scripts/make-app.sh", buildpath/"AgentIsland.app"
    # Zipped because brew rewrites Mach-O load paths in a keg, which breaks Sparkle's signature seal.
    system "ditto", "-c", "-k", "--keepParent", "AgentIsland.app", "AgentIsland.zip"
    libexec.install "install.sh", "scripts", "hooks", "AgentIsland.zip"
    (libexec/".build").install ".build/agentisland-ide-focus.vsix"
    # brew may not write outside its prefix, so this one command finishes the install.
    (bin/"agent-island").write <<~SH
      #!/bin/bash
      AGENTISLAND_PREBUILT="#{opt_libexec}/AgentIsland.zip" exec "#{opt_libexec}/install.sh" "$@"
    SH
  end

  def caveats
    <<~EOS
      Finish the install (copies the app to ~/Applications, adds agent hooks, starts it):
        agent-island
      Run it again after `brew upgrade agent-island`.
      To remove the hooks:  python3 #{opt_libexec}/scripts/uninstall-hooks.py
    EOS
  end

  test do
    assert_path_exists libexec/"AgentIsland.zip"
  end
end
