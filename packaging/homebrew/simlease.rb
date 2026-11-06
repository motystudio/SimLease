# Template: scripts/release.sh fills @VERSION@ and @SHA256@ and writes the result to
# motystudio/homebrew-tap as Casks/simlease.rb.
cask "simlease" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/motystudio/SimLease/releases/download/v#{version}/SimBar-#{version}.zip"
  name "SimLease"
  name "SimBar"
  desc "Share simulators and emulators between parallel Claude Code sessions"
  homepage "https://github.com/motystudio/SimLease"

  livecheck do
    url "https://github.com/motystudio/SimLease/releases/latest/download/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :sequoia

  app "SimBar.app"
  binary "#{appdir}/SimBar.app/Contents/Resources/sim-lease"

  uninstall quit: "com.motystudio.simbar"

  zap trash: [
    "~/.claude/sim-lease.conf",
    "~/.claude/sim-leases",
    "~/Library/Preferences/com.motystudio.simbar.plist",
  ]

  caveats <<~EOS
    Open SimBar once to finish the setup: in its panel, the gear menu > Setup installs
    ~/.claude/bin/sim-lease, the <simulators> rule in ~/.claude/CLAUDE.md and the
    SessionEnd hook that releases a session's devices.
      open -a SimBar
  EOS
end
