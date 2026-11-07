// SimBar — the window that shows an install from the gear menu step by step: the files change
// in the background in a fraction of a second, and without it nothing shows that they did.

import SwiftUI

/// One install: the state of each item, updated as the command queue goes through them.
@MainActor
final class InstallRun: ObservableObject {
    enum Status: Equatable { case pending, running, done, failed(String) }

    let items: [SetupItem]
    @Published private(set) var status: [SetupItem: Status]
    @Published var finished = false

    init(_ items: [SetupItem]) {
        self.items = items
        status = Dictionary(uniqueKeysWithValues: items.map { ($0, .pending) })
    }

    func set(_ item: SetupItem, _ new: Status) { status[item] = new }

    var failed: Bool { status.values.contains { if case .failed = $0 { return true } else { return false } } }
}

struct InstallProgressView: View {
    @ObservedObject var run: InstallRun
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(run.items, id: \.self) { row($0) }
            }
            if run.finished {
                Footnote(run.failed
                         ? L("You can try again from the gear menu once the error is fixed.",
                             "Vous pourrez réessayer depuis le menu engrenage une fois l'erreur corrigée.")
                         : L("Running sessions use the new script on their next call; the rule applies to new sessions.",
                             "Les sessions en cours utilisent le nouveau script dès leur prochain appel ; la règle s'applique aux nouvelles sessions."))
            }
            HStack {
                Spacer()
                Button(L("Done", "Terminé"), action: close)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!run.finished)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    var title: String {
        if !run.finished { return L("Installing…", "Installation en cours…") }
        return run.failed ? L("Some items couldn't be installed", "Certains éléments n'ont pas pu être installés")
                          : L("Everything is installed", "Tout est installé")
    }

    func row(_ item: SetupItem) -> some View {
        let status = run.status[item] ?? .pending
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch status {
            case .pending: Image(systemName: "circle").foregroundStyle(.tertiary).font(.system(size: 15)).frame(width: 18)
            case .running: ProgressView().controlSize(.small).frame(width: 18)
            case .done: StatusIcon(kind: .ok)
            case .failed: StatusIcon(kind: .error)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).foregroundStyle(status == .pending ? .secondary : .primary)
                Text(item.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if case .failed(let message) = status {
                    Text(message).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
