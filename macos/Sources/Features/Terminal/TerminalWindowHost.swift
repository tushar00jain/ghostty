import AppKit

/// Owns the real window. Each child controller owns one terminal and its split tree.
final class TerminalWindowHost: NSWindowController, NSWindowDelegate, FullscreenDelegate, TabGroupCloseCoordinator.Controller {
    private static var openHosts: [TerminalWindowHost] = []
    private let contentController = NSViewController()
    private let nibName: NSNib.Name
    private var contentArea: NSView?
    private var tabStrip: TerminalTabStrip?
    private(set) var selected: BaseTerminalController?
    var fullscreenStyle: FullscreenStyle?
    lazy private(set) var tabGroupCloseCoordinator = TabGroupCloseCoordinator()

    var controllers: [BaseTerminalController] {
        contentController.children.compactMap { $0 as? BaseTerminalController }
    }
    var terminals: [TerminalController] { controllers.compactMap { $0 as? TerminalController } }
    override var windowNibName: NSNib.Name? { nibName }

    init(_ controller: BaseTerminalController) {
        nibName = controller.windowNibName ?? "Terminal"
        super.init(window: nil)
        shouldCascadeWindows = false
        contentController.addChild(controller)
        selected = controller
        controller.windowHost = self
        Self.openHosts.append(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window, let selected else { return }
        let area = NSView()
        contentArea = area
        let strip = selected is TerminalController ? TerminalTabStrip() : nil
        tabStrip = strip
        contentController.view = TerminalWindowContent(area: area, strip: strip)
        window.contentViewController = contentController
        window.delegate = self
        strip?.onSelect = { [weak self] id in
            guard let self, let terminal = controllers.first(where: { $0.tabID == id }) else { return }
            select(terminal)
        }
        strip?.onClose = { [weak self] id in
            self?.terminals.first(where: { $0.tabID == id })?.closeTab(nil)
        }
        strip?.onNewTab = { [weak self] in (self?.selected as? TerminalController)?.newTab(nil) }
        strip?.onMove = { [weak self] id, gap in
            guard let self, let index = controllers.firstIndex(where: { $0.tabID == id }) else { return }
            move(controllers[index], to: gap > index ? gap - 1 : gap)
        }
        display(selected)
        selected.windowDidLoad()
        controllers.forEach { $0.focusedSurfaceDidChange(to: $0.focusedSurface ?? $0.surfaceTree.first) }
        refreshTabs()
    }

    func insert(_ controller: BaseTerminalController, at index: Int) {
        controller.windowHost = self
        contentController.insertChild(controller, at: min(index, controllers.count))
        if isWindowLoaded { controller.windowDidLoadForTab() }
        select(controller)
    }

    func remove(_ controller: BaseTerminalController) {
        guard let index = controllers.firstIndex(where: { $0 === controller }) else { return }
        if controllers.count == 1 {
            window?.close()
            return
        }
        let remaining = controllers.filter { $0 !== controller }
        if selected === controller { select(remaining[min(index, remaining.count - 1)]) }
        controller.terminalDidClose()
        controller.removeFromParent()
        controller.windowHost = nil
        refreshTabs()
        window?.invalidateRestorableState()
    }

    func move(_ controller: BaseTerminalController, to index: Int) {
        guard controllers.contains(where: { $0 === controller }) else { return }
        controller.removeFromParent()
        contentController.insertChild(controller, at: max(0, min(index, controllers.count)))
        refreshTabs()
        window?.invalidateRestorableState()
    }

    /// Reorder relative to another tab, using the same above/below convention as AppKit.
    func move(_ controller: BaseTerminalController, relativeTo target: BaseTerminalController, ordered: NSWindow.OrderingMode) {
        let others = controllers.filter { $0 !== controller }
        guard let index = others.firstIndex(of: target) else { return }
        move(controller, to: index + (ordered == .above ? 1 : 0))
    }

    func select(_ controller: BaseTerminalController) {
        guard controllers.contains(where: { $0 === controller }) else { return }
        let selectionChanged = selected !== controller
        if selectionChanged {
            selected?.focusedSurface?.focusDidChange(false)
            if selected?.isViewLoaded == true { selected?.view.removeFromSuperview() }
            selected = controller
        }
        guard isWindowLoaded else { return }
        if selectionChanged {
            display(controller)
            controllers.forEach { $0.syncSurfaceTreeOcclusionState() }
            controller.focusedSurfaceDidChange(to: controller.focusedSurface ?? controller.surfaceTree.first)
            refreshTabs()
            window?.invalidateRestorableState()
        }
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self, let controller, selected === controller,
                  !controller.commandPaletteIsShowing,
                  let surface = controller.focusedSurface, surface.window === window else { return }
            window?.makeFirstResponder(surface)
        }
    }

    private func display(_ controller: BaseTerminalController) {
        guard let contentArea, controller.view.superview !== contentArea else { return }
        contentController.view.layoutSubtreeIfNeeded()
        controller.view.frame = contentArea.bounds
        controller.view.autoresizingMask = [.width, .height]
        contentArea.addSubview(controller.view)
    }

    func refreshTabs() {
        guard isWindowLoaded else { return }
        if selected is TerminalController, let window {
            window.isRestorable = terminals.contains(where: { $0.restorable })
            if window.isRestorable {
                window.restorationClass = TerminalWindowRestoration.self
                window.identifier = .init(String(describing: TerminalWindowRestoration.self))
            }
        }
        if let terminal = selected as? TerminalController {
            terminal.relabelTabs()
        } else {
            updateTabStrip()
        }
    }

    func updateTabStrip() {
        let tabs = controllers.map { controller in
            TerminalTabStrip.Item(id: controller.tabID, title: controller.tabTitle, keyEquivalent: controller.keyEquivalent)
        }
        tabStrip?.update(tabs: tabs, selectedID: selected?.tabID)
    }

    override func newWindowForTab(_ sender: Any?) {
        (selected as? TerminalController)?.newWindowForTab(sender)
    }

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let selected, selected.responds(to: action) { return selected }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        selected?.windowShouldClose(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        for controller in controllers {
            controller.windowWillClose(notification)
            controller.removeFromParent()
            controller.windowHost = nil
        }
        selected = nil
        window?.contentViewController = nil
        Self.openHosts.removeAll { $0 === self }
    }

    func windowDidBecomeKey(_ notification: Notification) { selected?.windowDidBecomeKey(notification) }
    func windowDidResignKey(_ notification: Notification) { selected?.windowDidResignKey(notification) }
    func windowDidBecomeMain(_ notification: Notification) {
        (selected as? TerminalController)?.windowDidBecomeMain(notification)
    }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        controllers.forEach { $0.windowDidChangeOcclusionState(notification) }
    }
    func windowDidResize(_ notification: Notification) { selected?.windowDidResize(notification) }
    func windowDidMove(_ notification: Notification) { selected?.windowDidMove(notification) }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        selected?.windowWillReturnUndoManager(window)
    }
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        (selected as? TerminalController)?.window(window, willEncodeRestorableState: state)
    }
    func fullscreenDidChange() { controllers.forEach { $0.fullscreenDidChange() } }

    @IBAction func selectNextTerminalTab(_ sender: Any?) { selectRelativeTab(1) }
    @IBAction func selectPreviousTerminalTab(_ sender: Any?) { selectRelativeTab(-1) }

    private func selectRelativeTab(_ offset: Int) {
        guard let selected, let index = controllers.firstIndex(where: { $0 === selected }) else { return }
        select(controllers[(index + offset + controllers.count) % controllers.count])
    }
}

private final class TerminalWindowContent: NSView {
    private let area: NSView
    private let strip: NSView?

    init(area: NSView, strip: NSView?) {
        self.area = area
        self.strip = strip
        super.init(frame: .zero)
        area.translatesAutoresizingMaskIntoConstraints = false
        addSubview(area)
        NSLayoutConstraint.activate([
            area.leadingAnchor.constraint(equalTo: leadingAnchor),
            area.trailingAnchor.constraint(equalTo: trailingAnchor),
            area.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let strip {
            strip.translatesAutoresizingMaskIntoConstraints = false
            addSubview(strip)
            NSLayoutConstraint.activate([
                strip.leadingAnchor.constraint(equalTo: leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: trailingAnchor),
                strip.topAnchor.constraint(equalTo: topAnchor),
                strip.heightAnchor.constraint(equalToConstant: TerminalTabStrip.height),
                area.topAnchor.constraint(equalTo: strip.bottomAnchor),
            ])
        } else {
            area.topAnchor.constraint(equalTo: topAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize {
        guard let terminal = area.subviews.first else { return super.intrinsicContentSize }
        let size = terminal.intrinsicContentSize
        return NSSize(width: size.width, height: size.height + (strip == nil ? 0 : TerminalTabStrip.height))
    }
}

extension NSWindow {
    var terminalContentController: BaseTerminalController? {
        (windowController as? TerminalWindowHost)?.selected
    }
    var terminalContentControllers: [BaseTerminalController] {
        (windowController as? TerminalWindowHost)?.controllers ?? []
    }
}
