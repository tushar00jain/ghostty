import AppKit

/// A document-style tab strip. The owner retains terminal content and commits moves.
final class TerminalTabStrip: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    struct Item: Equatable {
        let id: UUID
        let title: String
    }

    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    /// The insertion gap in the original order, before removing the dragged item.
    var onMove: ((UUID, Int) -> Void)?
    var onNewTab: (() -> Void)?

    static let height: CGFloat = 50

    private static let itemIdentifier = NSUserInterfaceItemIdentifier("TerminalTab")
    private static let pasteboardType = NSPasteboard.PasteboardType("com.mitchellh.ghostty.terminal-tab")
    private let scrollView = NSScrollView()
    private let collectionView = TerminalTabCollectionView()
    private let plusButton = NSButton()
    private let flowLayout = NSCollectionViewFlowLayout()
    private var tabs: [Item] = []
    private var selectedID: UUID?
    private var updating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        flowLayout.scrollDirection = .horizontal
        flowLayout.itemSize = NSSize(width: 116, height: 28)
        flowLayout.sectionInset = NSEdgeInsets(top: 11, left: 16, bottom: 10, right: 4)
        flowLayout.minimumLineSpacing = 0
        flowLayout.minimumInteritemSpacing = 0
        collectionView.collectionViewLayout = flowLayout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TerminalTabCollectionItem.self, forItemWithIdentifier: Self.itemIdentifier)
        collectionView.registerForDraggedTypes([Self.pasteboardType])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.setDraggingSourceOperationMask([], forLocal: false)

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false

        plusButton.isBordered = false
        plusButton.title = "+"
        plusButton.font = .systemFont(ofSize: 19, weight: .ultraLight)
        plusButton.setAccessibilityLabel("New Tab")
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.toolTip = "New Tab"
        plusButton.target = self
        plusButton.action = #selector(newTab)
        for view in [scrollView, plusButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            scrollView.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor, constant: -4),
            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            plusButton.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: 28),
            plusButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    override func layout() {
        super.layout()
        let available = max(0, scrollView.contentSize.width - 20)
        let itemWidth = tabs.isEmpty ? 116 : min(214, max(116, available / CGFloat(tabs.count)))
        flowLayout.itemSize = NSSize(width: itemWidth, height: 28)
        collectionView.setFrameSize(NSSize(
            width: max(scrollView.contentSize.width, CGFloat(tabs.count) * itemWidth + 20),
            height: scrollView.contentSize.height))
        collectionView.railRect = NSRect(x: 16, y: 11, width: itemWidth * CGFloat(tabs.count), height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func update(tabs: [Item], selectedID: UUID?) {
        guard self.tabs != tabs || self.selectedID != selectedID else { return }
        let itemsChanged = self.tabs != tabs
        let revealSelection = self.selectedID != selectedID
        updating = true
        defer { updating = false }
        self.tabs = tabs
        self.selectedID = selectedID
        if itemsChanged {
            collectionView.reloadData()
        } else {
            for item in collectionView.visibleItems() {
                guard let index = collectionView.indexPath(for: item)?.item,
                      tabs.indices.contains(index), let view = item.view as? TerminalTabItemView else { continue }
                view.update(title: tabs[index].title, selected: tabs[index].id == selectedID)
                view.showsSeparator = index + 1 < tabs.count && tabs[index + 1].id != selectedID
            }
        }
        let selectedIndex = tabs.firstIndex { $0.id == selectedID }
        collectionView.selectionIndexPaths = Set(selectedIndex.map { [IndexPath(item: $0, section: 0)] } ?? [])
        needsLayout = true
        layoutSubtreeIfNeeded()
        if revealSelection, let selectedIndex {
            collectionView.scrollToItems(at: [IndexPath(item: selectedIndex, section: 0)], scrollPosition: .nearestHorizontalEdge)
        }
    }

    @objc private func newTab() { onNewTab?() }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        tabs.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemIdentifier, for: indexPath)
        guard let tabView = item.view as? TerminalTabItemView else { return item }
        let tab = tabs[indexPath.item]
        tabView.update(title: tab.title, selected: tab.id == selectedID)
        tabView.showsSeparator = indexPath.item + 1 < tabs.count && tabs[indexPath.item + 1].id != selectedID
        tabView.onSelect = { [weak self] in self?.onSelect?(tab.id) }
        tabView.onClose = { [weak self] in self?.onClose?(tab.id) }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !updating, let index = indexPaths.first?.item, tabs.indices.contains(index) else { return }
        onSelect?(tabs[index].id)
    }

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard tabs.count > 1, tabs.indices.contains(indexPath.item) else { return nil }
        let item = NSPasteboardItem()
        item.setString(tabs[indexPath.item].id.uuidString, forType: Self.pasteboardType)
        return item
    }

    private func draggedID(_ info: NSDraggingInfo) -> UUID? {
        guard (info.draggingSource as? NSCollectionView) === collectionView,
              let value = info.draggingPasteboard.string(forType: Self.pasteboardType),
              let id = UUID(uuidString: value), tabs.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard draggedID(info) != nil else { return [] }
        dropOperation.pointee = .before
        return .move
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let id = draggedID(info), (0...tabs.count).contains(indexPath.item) else { return false }
        onMove?(id, indexPath.item)
        return true
    }
}

// Tab appearance adapted directly from TU Code’s EditorAreaView.swift.
// Let NSCollectionView track selection and dragging from the label. The close button
// keeps normal NSButton tracking, and accessibility presses still use its target/action.
private final class TerminalTabSelectButton: NSButton {
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
}

private final class TerminalTabItemView: NSView {
    private let selectButton = TerminalTabSelectButton()
    private let closeButton = NSButton()
    fileprivate private(set) var active = false
    var showsSeparator = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        selectButton.isBordered = false
        selectButton.alignment = .center
        selectButton.font = .systemFont(ofSize: 11, weight: .medium)
        selectButton.imagePosition = .imageLeading
        selectButton.imageHugsTitle = true
        selectButton.imageScaling = .scaleNone
        selectButton.lineBreakMode = .byTruncatingMiddle
        selectButton.target = self
        selectButton.action = #selector(selectTab)
        closeButton.title = ""
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.alphaValue = 0
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        for child in [selectButton, closeButton] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            selectButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            selectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            selectButton.topAnchor.constraint(equalTo: topAnchor),
            selectButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { closeButton.alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { closeButton.alphaValue = 0 }

    func update(title: String, selected: Bool) {
        active = selected
        needsDisplay = true
        selectButton.title = title
        selectButton.toolTip = title
        selectButton.contentTintColor = selected
            ? NSColor(calibratedWhite: 0.84, alpha: 1)
            : NSColor(calibratedWhite: 0.66, alpha: 1)
        selectButton.setAccessibilitySelected(selected)
        selectButton.setAccessibilityLabel(title)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close \(title)")
        closeButton.setAccessibilityLabel("Close \(title)")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if active {
            let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 12, yRadius: 12)
            NSColor(srgbRed: 84 / 255, green: 84 / 255, blue: 84 / 255, alpha: 1).setFill()
            pill.fill()
            NSColor(srgbRed: 115 / 255, green: 115 / 255, blue: 115 / 255, alpha: 1).setStroke()
            pill.lineWidth = 1
            pill.stroke()
        } else if showsSeparator {
            NSColor(srgbRed: 76 / 255, green: 75 / 255, blue: 75 / 255, alpha: 1).setFill()
            NSRect(x: bounds.maxX - 1, y: 7, width: 1, height: 15).fill()
        }
    }

    @objc private func selectTab() { onSelect?() }
    @objc private func closeTab() { onClose?() }
}

private final class TerminalTabCollectionItem: NSCollectionViewItem {
    override func loadView() { view = TerminalTabItemView(frame: .zero) }

    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = view.bounds
        return [component]
    }
}

private final class TerminalTabCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
    var railRect = NSRect.zero { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !railRect.isEmpty else { return }
        NSColor(srgbRed: 52 / 255, green: 51 / 255, blue: 51 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: railRect, xRadius: 14, yRadius: 14).fill()
    }
}
