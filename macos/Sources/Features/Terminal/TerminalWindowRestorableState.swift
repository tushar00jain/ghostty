import AppKit

/// Window restoration wraps the existing, independent terminal states.
final class TerminalWindowRestorableState: TerminalRestorable {
    static var version: Int { 1 }
    static var selfKey: String { "terminalTabs" }

    let tabs: [TerminalRestorableState]
    let selectedTab: Int

    init(from host: TerminalWindowHost) {
        let terminals = host.terminals.filter { $0.restorable }
        tabs = terminals.map { TerminalRestorableState(from: $0) }
        selectedTab = terminals.firstIndex(where: { $0 === host.selected }) ?? 0
    }

    required init(copy other: TerminalWindowRestorableState) {
        tabs = other.tabs
        selectedTab = other.selectedTab
    }
}
