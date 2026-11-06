// SimBar — what needs to be in ~/.claude for sim-lease to work, and the requirements check.

import Foundation

// MARK: - Setup (what needs to be in ~/.claude for sim-lease to work)

enum SetupItem: CaseIterable {
    case script, rule, hook

    var title: String {
        switch self {
        case .script: return L("sim-lease script", "Script sim-lease")
        case .rule: return L("CLAUDE.md rule", "Règle CLAUDE.md")
        case .hook: return L("SessionEnd hook", "Hook SessionEnd")
        }
    }

    /// What installing it changes on disk, in one line.
    var detail: String {
        switch self {
        case .script:
            return L("Copies the script to ~/.claude/bin/sim-lease.",
                     "Copie le script dans ~/.claude/bin/sim-lease.")
        case .rule:
            return L("Adds a <simulators> section to ~/.claude/CLAUDE.md telling Claude to lease devices.",
                     "Ajoute une section <simulators> à ~/.claude/CLAUDE.md pour que Claude loue les appareils.")
        case .hook:
            return L("Adds a hook to ~/.claude/settings.json that frees a session's devices when it ends (backup kept).",
                     "Ajoute à ~/.claude/settings.json un hook qui libère les appareils d'une session quand elle se termine (copie de sauvegarde conservée).")
        }
    }
}

enum SetupState: Equatable { case ok, missing, outdated }

/// Checks and installs the script, the CLAUDE.md rule and the SessionEnd hook, from the
/// copies bundled in the app. `claudeDir` is ~/.claude (another folder for `--setup` tests).
struct Setup {
    let claudeDir: String
    static let hookCommand = "$HOME/.claude/bin/sim-lease release-session"
    private static let ruleStart = "<simulators>", ruleEnd = "</simulators>"

    private var scriptPath: String { "\(claudeDir)/bin/sim-lease" }
    private var rulePath: String { "\(claudeDir)/CLAUDE.md" }
    private var settingsPath: String { "\(claudeDir)/settings.json" }
    /// A copy shipped in the app's Resources ("" when running a bare binary: reads as outdated, installing fails).
    private func bundled(_ name: String) -> String { Bundle.main.path(forResource: name, ofType: nil) ?? "" }

    func state(_ item: SetupItem) -> SetupState {
        let fm = FileManager.default
        switch item {
        case .script:
            guard fm.fileExists(atPath: scriptPath) else { return .missing }
            return fm.contentsEqual(atPath: scriptPath, andPath: bundled("sim-lease")) ? .ok : .outdated
        case .rule:
            guard let md = try? String(contentsOfFile: rulePath, encoding: .utf8),
                  let block = Setup.ruleBlock(in: md) else { return .missing }
            let snippet = (try? String(contentsOfFile: bundled("CLAUDE.snippet.md"), encoding: .utf8)) ?? ""
            return md[block].trimmingCharacters(in: .whitespacesAndNewlines)
                == snippet.trimmingCharacters(in: .whitespacesAndNewlines) ? .ok : .outdated
        case .hook:
            guard let data = fm.contents(atPath: settingsPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = json["hooks"] as? [String: Any],
                  let end = hooks["SessionEnd"] as? [[String: Any]] else { return .missing }
            let commands = end.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
            return commands.contains { $0.contains("sim-lease release-session") } ? .ok : .missing
        }
    }

    func install(_ item: SetupItem) throws {
        guard state(item) != .ok else { return }   // never add a second hook or rule
        let fm = FileManager.default
        if item != .hook, bundled(item == .script ? "sim-lease" : "CLAUDE.snippet.md").isEmpty {
            throw Setup.error(L("This copy of SimBar doesn't include it; build it with build.sh.",
                                "Cette copie de SimBar ne le contient pas ; compilez-la avec build.sh."))
        }
        try fm.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        switch item {
        case .script:
            try fm.createDirectory(atPath: "\(claudeDir)/bin", withIntermediateDirectories: true)
            try? fm.removeItem(atPath: scriptPath)   // also replaces an old symlink into the repo
            try fm.copyItem(atPath: bundled("sim-lease"), toPath: scriptPath)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        case .rule:
            let snippet = try String(contentsOfFile: bundled("CLAUDE.snippet.md"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var md = (try? String(contentsOfFile: rulePath, encoding: .utf8)) ?? ""
            if let block = Setup.ruleBlock(in: md) {
                md.replaceSubrange(block, with: snippet)
            } else {
                md += (md.isEmpty || md.hasSuffix("\n\n") ? "" : md.hasSuffix("\n") ? "\n" : "\n\n") + snippet + "\n"
            }
            try md.write(toFile: rulePath, atomically: true, encoding: .utf8)
        case .hook:
            // jq keeps the user's key order and formatting; a backup is kept next to the file
            if !fm.fileExists(atPath: settingsPath) { try "{}\n".write(toFile: settingsPath, atomically: true, encoding: .utf8) }
            let backup = settingsPath + ".backup-simbar"
            try? fm.removeItem(atPath: backup)
            try fm.copyItem(atPath: settingsPath, toPath: backup)
            let filter = #".hooks.SessionEnd = ((.hooks.SessionEnd // []) + [{"hooks":[{"type":"command","command":$c,"timeout":30}]}])"#
            let jq = execute("/usr/bin/jq", ["--arg", "c", Setup.hookCommand, filter, settingsPath], timeout: 30)
            guard jq.ok, !jq.output.isEmpty else {
                throw Setup.error(jq.status == -1 ? L("/usr/bin/jq is missing.", "/usr/bin/jq est introuvable.")
                                  : L("jq could not update settings.json", "jq n'a pas pu modifier settings.json")
                                    + (jq.error.isEmpty ? "" : ": \(jq.error)"))
            }
            let perms = try fm.attributesOfItem(atPath: settingsPath)[.posixPermissions]
            try jq.output.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            if let perms { try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: settingsPath) }
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "SimBar", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func ruleBlock(in md: String) -> Range<String.Index>? {
        guard let start = md.range(of: ruleStart), let end = md.range(of: ruleEnd, range: start.upperBound..<md.endIndex)
        else { return nil }
        return start.lowerBound..<end.upperBound
    }
}

// MARK: - Requirements (what sim-lease needs on this Mac)

struct Requirement: Identifiable, Equatable {
    enum Kind: CaseIterable { case xcode, jq, claude, android }

    let kind: Kind
    let met: Bool
    /// What was found, or what to do about it.
    let detail: String
    /// Where to get it, when it is missing.
    var link: URL? = nil

    var id: Kind { kind }
    var required: Bool { kind != .android }

    var title: String {
        switch kind {
        case .xcode: return L("Xcode (xcrun simctl)", "Xcode (xcrun simctl)")
        case .jq: return "jq"
        case .claude: return "Claude Code"
        case .android: return L("Android SDK (optional)", "SDK Android (facultatif)")
        }
    }

    /// Checks everything. Blocking (runs xcode-select / xcrun): call it off the main thread.
    static func checkAll() -> [Requirement] { Kind.allCases.map(check) }

    static func check(_ kind: Kind) -> Requirement {
        let fm = FileManager.default
        switch kind {
        case .xcode:
            let appStore = URL(string: "macappstore://apps.apple.com/app/id497799835")
            // xcode-select first: with no developer tools at all, xcrun would pop up an install dialog
            let selected = execute("/usr/bin/xcode-select", ["-p"], timeout: 10)
            let dir = String(decoding: selected.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard selected.ok, !dir.isEmpty else {
                return Requirement(kind: kind, met: false, detail: L("Install Xcode from the App Store and open it once.",
                                                                     "Installez Xcode depuis l'App Store et ouvrez-le une fois."), link: appStore)
            }
            guard execute("/usr/bin/xcrun", ["--find", "simctl"], timeout: 20).ok else {
                return Requirement(kind: kind, met: false, detail: dir.contains("CommandLineTools")
                    ? L("Only the command line tools are selected. Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app",
                        "Seuls les outils en ligne de commande sont sélectionnés. Installez Xcode, puis lancez : sudo xcode-select -s /Applications/Xcode.app")
                    : L("simctl wasn't found. Open Xcode once to finish installing it.",
                        "simctl est introuvable. Ouvrez Xcode une fois pour terminer son installation."), link: appStore)
            }
            let app = dir.range(of: ".app/").map { String(dir[..<$0.lowerBound]) + ".app" } ?? dir
            return Requirement(kind: kind, met: true, detail: tilde(app))
        case .jq:
            let ok = fm.isExecutableFile(atPath: "/usr/bin/jq")
            return Requirement(kind: kind, met: ok, detail: ok ? "/usr/bin/jq"
                               : L("Included in macOS 15 and later: update macOS.", "Inclus dans macOS 15 et ultérieur : mettez macOS à jour."))
        case .claude:
            let ok = fm.fileExists(atPath: "\(home)/.claude")
            return Requirement(kind: kind, met: ok, detail: ok ? "~/.claude"
                               : L("Install Claude Code and run it once, so ~/.claude exists.",
                                   "Installez Claude Code et lancez-le une fois pour créer ~/.claude."),
                               link: ok ? nil : URL(string: "https://claude.com/claude-code"))
        case .android:
            let env = ProcessInfo.processInfo.environment
            let candidates = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], "\(home)/Library/Android/sdk"].compactMap { $0 }
            if let sdk = candidates.first(where: { fm.isExecutableFile(atPath: "\($0)/platform-tools/adb") }) {
                return Requirement(kind: kind, met: true, detail: tilde(sdk))
            }
            return Requirement(kind: kind, met: false, detail: L("Not found. Only needed for Android emulators.",
                                                                 "Introuvable. Nécessaire seulement pour les émulateurs Android."))
        }
    }

    private static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

