// SimBar — what needs to be in ~/.claude for sim-lease to work, and the requirements check.

import Foundation
import CryptoKit

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
            return L("Adds a <simulators> section to ~/.claude/CLAUDE.md telling Claude to lease devices (backup kept).",
                     "Ajoute une section <simulators> à ~/.claude/CLAUDE.md pour que Claude loue les appareils (copie de sauvegarde conservée).")
        case .hook:
            return L("Adds a hook to ~/.claude/settings.json that frees a session's devices when it ends (backup kept).",
                     "Ajoute à ~/.claude/settings.json un hook qui libère les appareils d'une session quand elle se termine (copie de sauvegarde conservée).")
        }
    }
}

enum SetupState: Equatable {
    case ok, missing, outdated
    /// The CLAUDE.md rule was edited by hand: it counts as installed and is only ever replaced
    /// when the user asks for it.
    case customized
    /// CLAUDE.md has `<simulators>` without `</simulators>`: needs attention, fixed only when asked.
    case malformed

    var isInstalled: Bool { self == .ok || self == .customized }
    /// What "Install" / "Install everything" may do without asking first.
    var installsSilently: Bool { self == .missing || self == .outdated }
}

/// Checks and installs the script, the CLAUDE.md rule and the SessionEnd hook, from the
/// copies bundled in the app. `claudeDir` is ~/.claude (another folder for `--setup` tests).
///
/// CLAUDE.md and settings.json are often symlinks into a dotfiles repo: they are read and
/// written through the link (the link stays, the file it points to is updated, with its
/// permissions), and a backup of the previous content is saved next to the link first.
struct Setup {
    let claudeDir: String
    /// Quoted, so a home folder whose path contains a space works.
    static let hookCommand = #""$HOME/.claude/bin/sim-lease" release-session"#
    /// What earlier builds wrote; found as outdated and rewritten as `hookCommand`.
    static let legacyHookCommand = "$HOME/.claude/bin/sim-lease release-session"
    static let backupSuffix = ".backup-simbar"

    private var scriptPath: String { "\(claudeDir)/bin/sim-lease" }
    private var rulePath: String { "\(claudeDir)/CLAUDE.md" }
    private var settingsPath: String { "\(claudeDir)/settings.json" }
    /// A copy shipped in the app's Resources ("" when running a bare binary: reads as outdated, installing fails).
    private func bundled(_ name: String) -> String { Bundle.main.path(forResource: name, ofType: nil) ?? "" }
    private var bundledRule: String? { try? String(contentsOfFile: bundled("CLAUDE.snippet.md"), encoding: .utf8) }

    func state(_ item: SetupItem) -> SetupState {
        let fm = FileManager.default
        switch item {
        case .script:
            guard fm.fileExists(atPath: scriptPath) else { return .missing }
            return fm.contentsEqual(atPath: scriptPath, andPath: bundled("sim-lease")) ? .ok : .outdated
        case .rule:
            guard let md = try? String(contentsOfFile: rulePath, encoding: .utf8) else { return .missing }
            switch Rule.find(in: md) {
            case .none: return .missing
            case .unterminated: return .malformed
            case .block(let range): return Rule.state(of: String(md[range]), bundled: bundledRule)
            }
        case .hook:
            guard let data = fm.contents(atPath: settingsPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = json["hooks"] as? [String: Any],
                  let end = hooks["SessionEnd"] as? [[String: Any]] else { return .missing }
            let commands = end.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
            if commands.contains(Setup.hookCommand) { return .ok }
            if commands.contains(Setup.legacyHookCommand) { return .outdated }
            // a hook the user wrote themselves (another path, a wrapper…) is theirs to keep
            return commands.contains { $0.contains("sim-lease") && $0.contains("release-session") } ? .ok : .missing
        }
    }

    /// Installs or updates `item` when it is missing or outdated; does nothing otherwise, so it
    /// never adds a second hook or rule. A customized or malformed rule is replaced only with
    /// `replacingRule`, once the user has confirmed it.
    func install(_ item: SetupItem, replacingRule: Bool = false) throws {
        let current = state(item)
        guard current.installsSilently || (item == .rule && replacingRule && current != .ok) else { return }
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
            let rule = Rule.rendered(try String(contentsOfFile: bundled("CLAUDE.snippet.md"), encoding: .utf8))
            let target = try Setup.resolvingSymlinks(rulePath)
            let original: Data? = fm.fileExists(atPath: target) ? try Data(contentsOf: URL(fileURLWithPath: target)) : nil
            guard var md = String(data: original ?? Data(), encoding: .utf8) else {
                throw Setup.error(L("CLAUDE.md isn't UTF-8 text; add the rule by hand.",
                                    "CLAUDE.md n'est pas du texte UTF-8 ; ajoutez la règle à la main."))
            }
            switch Rule.find(in: md) {
            case .block(let range), .unterminated(let range):
                md.replaceSubrange(range, with: rule)
            case .none:
                md += (md.isEmpty || md.hasSuffix("\n\n") ? "" : md.hasSuffix("\n") ? "\n" : "\n\n") + rule + "\n"
            }
            try save(Data(md.utf8), to: target, original: original, backup: rulePath + Setup.backupSuffix)
        case .hook:
            // jq keeps the user's key order and formatting; a backup is kept next to the file
            let target = try Setup.resolvingSymlinks(settingsPath)
            let original: Data? = fm.fileExists(atPath: target) ? try Data(contentsOf: URL(fileURLWithPath: target)) : nil
            let filter = current == .outdated
                // rewrite the old unquoted command in place, wherever it is
                ? #".hooks.SessionEnd |= map(if type == "object" and (.hooks | type) == "array" then .hooks |= map(if type == "object" and .command == $old then .command = $c else . end) else . end)"#
                : #".hooks.SessionEnd = ((.hooks.SessionEnd // []) + [{"hooks":[{"type":"command","command":$c,"timeout":30}]}])"#
            let args = ["--arg", "c", Setup.hookCommand, "--arg", "old", Setup.legacyHookCommand]
                + (original?.isEmpty == false ? [filter, target] : ["-n", "{} | " + filter])
            let jq = execute("/usr/bin/jq", args, timeout: 30)
            guard jq.ok, !jq.output.isEmpty else {
                throw Setup.error(jq.status == -1 ? L("/usr/bin/jq is missing.", "/usr/bin/jq est introuvable.")
                                  : L("jq could not update settings.json", "jq n'a pas pu modifier settings.json")
                                    + (jq.error.isEmpty ? "" : ": \(jq.error)"))
            }
            try save(jq.output, to: target, original: original, backup: settingsPath + Setup.backupSuffix)
        }
    }

    /// Backs up `original` (when the file existed), then replaces `target` atomically, keeping
    /// its permissions (0644 for a new file). `target` has its symlinks resolved already; the
    /// backup is a plain file next to the path the user knows, with the same permissions.
    private func save(_ data: Data, to target: String, original: Data?, backup: String) throws {
        var permissions: mode_t = 0o644
        if original != nil, let mode = (try? FileManager.default.attributesOfItem(atPath: target))?[.posixPermissions] as? NSNumber {
            permissions = mode_t(mode.uint16Value & 0o7777)
        }
        if let original { try Setup.writeAtomically(original, to: backup, permissions: permissions) }
        try Setup.writeAtomically(data, to: target, permissions: permissions)
    }

    /// The file `path` ends up at, following symlinks one hop at a time (so a dangling link
    /// gives the file to create, rather than the link itself).
    static func resolvingSymlinks(_ path: String) throws -> String {
        var current = path
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { return current }
            current = destination.hasPrefix("/") ? destination
                : ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
        }
        throw error(L("Too many symbolic links: \(path)", "Trop de liens symboliques : \(path)"))
    }

    /// Writes a temporary file next to `path` with `permissions`, then renames it over `path`:
    /// readers see the old file or the new one, never half of it, and the mode never widens.
    static func writeAtomically(_ data: Data, to path: String, permissions: mode_t) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let temp = "\(dir)/.\(name).simbar-\(UUID().uuidString.prefix(8))"
        func failure(_ what: String) -> NSError {
            error(L("Couldn't write \(path) (\(what)): ", "Impossible d'écrire \(path) (\(what)) : ") + String(cString: strerror(errno)))
        }
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw failure("open") }
        var renamed = false
        defer { if !renamed { unlink(temp) } }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize() } catch {
            throw Setup.error(L("Couldn't write \(path): ", "Impossible d'écrire \(path) : ") + error.localizedDescription)
        }
        guard fchmod(fd, permissions) == 0 else { throw failure("chmod") }
        try? handle.close()
        guard rename(temp, path) == 0 else { throw failure("rename") }
        renamed = true
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "SimBar", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// The `<simulators>` … `</simulators>` block in CLAUDE.md.
///
/// SimBar writes a marker line right after `<simulators>`: `<!-- simbar-rule HASH -->`, HASH being
/// the first 16 hex digits of the SHA-256 of the block as SimBar wrote it (normalized, marker line
/// left out). On the next check the block is hashed again: same hash, nobody touched it, so it can
/// be updated to a newer rule; another hash, the user edited it, and it is left alone. Blocks
/// written before the marker existed are recognized by `previousHashes`. The bundled snippet
/// doesn't need a marker (one in it is ignored): SimBar adds its own when writing.
enum Rule {
    static let start = "<simulators>", end = "</simulators>"
    static let markerPrefix = "<!-- simbar-rule "

    /// Hashes of the rule texts earlier builds wrote without a marker.
    static let previousHashes: Set<String> = [
        "12d640e3a4bc815a",   // first version (--name Calqo_Phone)
        "ae7660a2e16781c5",   // 1.0.0 (--name Pixel_9_API_35)
    ]

    enum Location: Equatable {
        case none
        /// From `<simulators>` through `</simulators>`.
        case block(Range<String.Index>)
        /// `<simulators>` with no `</simulators>` after it: from the tag up to the next line that
        /// opens another section (`<name>` alone on its line) or the end of the file.
        case unterminated(Range<String.Index>)
    }

    /// Only a `<simulators>` that starts a line counts, so prose mentioning the tag is ignored.
    static func find(in md: String) -> Location {
        var lineStart = md.startIndex
        var opening: String.Index?
        var lastContent: String.Index?   // end of the last non-blank line seen after the opening tag
        while lineStart < md.endIndex {
            let line = md.lineRange(for: lineStart..<lineStart)
            let text = md[line].trimmingCharacters(in: .whitespacesAndNewlines)
            if let openTag = opening {
                if let close = md.range(of: end, range: line) { return .block(openTag..<close.upperBound) }
                if isSectionTag(text) { return .unterminated(openTag..<(lastContent ?? line.lowerBound)) }
                if !text.isEmpty { lastContent = contentEnd(of: line, in: md) }
            } else if text.hasPrefix(start), let tag = md.range(of: start, range: line) {
                opening = tag.lowerBound
                if let close = md.range(of: end, range: tag.upperBound..<line.upperBound) { return .block(tag.lowerBound..<close.upperBound) }
                lastContent = contentEnd(of: line, in: md)
            }
            lineStart = line.upperBound
        }
        if let openTag = opening { return .unterminated(openTag..<(lastContent ?? md.endIndex)) }
        return .none
    }

    static func state(of block: String, bundled: String?) -> SetupState {
        let body = normalized(block)
        if let bundled, body == normalized(bundled) { return .ok }   // also a block pasted by hand
        if let marker = marker(in: block) { return marker == hash(body) ? .outdated : .customized }
        return previousHashes.contains(hash(body)) ? .outdated : .customized
    }

    /// The bundled snippet as SimBar writes it: normalized, with its marker line.
    static func rendered(_ snippet: String) -> String {
        let body = normalized(snippet)
        var lines = body.components(separatedBy: "\n")
        lines.insert("\(markerPrefix)\(hash(body)) -->", at: min(1, lines.count))
        return lines.joined(separator: "\n")
    }

    /// Unix line ends, no trailing spaces, no blank lines around it, no marker line.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(markerPrefix) }
            .map { $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hash(_ normalizedText: String) -> String {
        SHA256.hash(data: Data(normalizedText.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func marker(in block: String) -> String? {
        for line in block.components(separatedBy: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(markerPrefix), text.hasSuffix("-->") else { continue }
            return text.dropFirst(markerPrefix.count).dropLast(3).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func isSectionTag(_ text: String) -> Bool {
        text.range(of: #"^<[A-Za-z][A-Za-z0-9_.-]*>$"#, options: .regularExpression) != nil
    }

    private static func contentEnd(of line: Range<String.Index>, in md: String) -> String.Index {
        var end = line.upperBound
        while end > line.lowerBound, md[md.index(before: end)].isWhitespace { end = md.index(before: end) }
        return end
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

