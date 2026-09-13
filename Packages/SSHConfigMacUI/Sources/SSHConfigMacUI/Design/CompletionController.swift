//
//  CompletionController.swift
//  sshconfigmanager
//
//  The AppKit half of raw-editor IntelliSense: a Xcode-style completion popup that
//  floats under the cursor and lists `CompletionItem`s from `IntelliSenseEngine`.
//
//  It's a *non-activating* `NSPanel`, so the text view keeps first-responder status
//  and never loses focus while the popup is up. That's the whole trick: arrow / return
//  / escape keystrokes keep flowing to the text view, whose delegate (the CodeEditor
//  coordinator) forwards them here via `doCommandBy`. The popup itself is pure display
//  + selection state; it never steals the keyboard.
//

import AppKit
import SSHConfigIntelliSense

@MainActor
final class CompletionController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var items: [CompletionItem] = []
    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var scrollView: NSScrollView?

    // Documentation lives in its OWN floating panel beside the list — detached, so its
    // height is driven by the documentation content (not the suggestion count) and it
    // never collapses to a sliver when only a couple of suggestions are shown.
    private var docPanel: NSPanel?
    private var docScrollView: NSScrollView?
    private var docTextView: NSTextView?
    private weak var hostWindow: NSWindow?

    /// Whether to show the documentation panel at all (user setting). When false, only
    /// the suggestion list appears.
    var documentationEnabled = true

    private let rowHeight: CGFloat = 24
    private let maxVisibleRows = 8
    private let listWidth: CGFloat = 360
    private let docWidth: CGFloat = 300
    private let docGap: CGFloat = 8
    private let minDocHeight: CGFloat = 96
    private let maxDocHeight: CGFloat = 280

    var isVisible: Bool { panel?.isVisible == true }

    var selectedItem: CompletionItem? {
        guard let table = tableView, table.selectedRow >= 0, table.selectedRow < items.count else { return nil }
        return items[table.selectedRow]
    }

    // MARK: - Lifecycle

    /// Show or refresh the popup with `items`, anchored to `screenRect` (the cursor's
    /// rect in screen coordinates) below the caret. Hides itself if `items` is empty.
    func show(items: [CompletionItem], anchoredTo screenRect: NSRect, in parentWindow: NSWindow?) {
        guard !items.isEmpty else {
            hide()
            return
        }
        self.items = items

        hostWindow = parentWindow
        let panel = ensurePanel()
        if let parentWindow, panel.parent == nil {
            parentWindow.addChildWindow(panel, ordered: .above)
        }

        // The suggestion list is its own box: cap the visible rows (extras scroll),
        // height is exactly what we draw. Frame-based layout — a borderless window
        // collapses to an Auto-Layout content view's minimum fitting height.
        let visibleRows = min(items.count, maxVisibleRows)
        let height = CGFloat(visibleRows) * rowHeight + 2
        panel.setContentSize(NSSize(width: listWidth, height: height))
        scrollView?.frame = NSRect(x: 0, y: 1, width: listWidth, height: height - 2)

        tableView?.reloadData()
        selectFirst()

        // Drop the popup just below the caret; flip above if it would clip the screen.
        var origin = NSPoint(x: screenRect.minX, y: screenRect.minY - height - 2)
        if let screen = parentWindow?.screen ?? NSScreen.main {
            if origin.y < screen.visibleFrame.minY {
                origin.y = screenRect.maxY + 2
            }
            origin.x = min(origin.x, screen.visibleFrame.maxX - listWidth - 4)
            origin.x = max(origin.x, screen.visibleFrame.minX + 4)
        }
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)

        updateDocs() // positions the detached docs panel beside this one
    }

    func hide() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        hideDocs()
        items = []
        tableView?.reloadData() // keep the table's row count in sync with `items`
    }

    private func hideDocs() {
        guard let docPanel else { return }
        docPanel.parent?.removeChildWindow(docPanel)
        docPanel.orderOut(nil)
    }

    // MARK: - Keyboard-driven selection (called from the text view's doCommandBy)

    func moveSelection(by delta: Int) {
        guard let table = tableView, !items.isEmpty else { return }
        let current = table.selectedRow < 0 ? -1 : table.selectedRow
        let next = max(0, min(items.count - 1, current + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
        updateDocs()
    }

    private func selectFirst() {
        guard let table = tableView, !items.isEmpty else { return }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)
    }

    /// Refresh, size, and position the detached documentation panel for the selected
    /// item. Shows it (beside the list) only when docs are enabled and the item has
    /// documentation; otherwise hides it. Called on show and every selection change.
    private func updateDocs() {
        guard documentationEnabled,
            let listPanel = panel,
            let item = selectedItem,
            let doc = item.documentation, !doc.isEmpty
        else {
            hideDocs()
            return
        }

        let docPanel = ensureDocPanel()
        if let host = hostWindow, docPanel.parent == nil {
            host.addChildWindow(docPanel, ordered: .above)
        }

        // Title (+ optional detail), then the documentation body.
        let body = NSMutableAttributedString(
            string: item.label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        if let detail = item.detail, !detail.isEmpty {
            body.append(
                NSAttributedString(
                    string: "  " + detail,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
        }
        body.append(
            NSAttributedString(
                string: "\n\n" + doc,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.labelColor,
                ]))
        docTextView?.textStorage?.setAttributedString(body)

        // Size to the content, clamped to a comfortable range (scrolls past the max).
        let textWidth = docWidth - 20
        let measured = body.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        let docHeight = min(max(ceil(measured) + 22, minDocHeight), maxDocHeight)
        docPanel.setContentSize(NSSize(width: docWidth, height: docHeight))

        // Place it to the right of the list, top-aligned; flip to the left if it would
        // run off the screen edge.
        let list = listPanel.frame
        var x = list.maxX + docGap
        var y = list.maxY - docHeight
        if let screen = hostWindow?.screen ?? NSScreen.main {
            if x + docWidth > screen.visibleFrame.maxX - 4 {
                x = list.minX - docWidth - docGap
            }
            y = max(y, screen.visibleFrame.minY + 4)
        }
        docPanel.setFrameOrigin(NSPoint(x: x, y: y))
        docPanel.orderFront(nil)
    }

    // MARK: - Panel construction

    /// A borderless, non-activating, menu-styled floating box (shared by the list and
    /// the docs panels). Frame-based content view so its size is exactly what we set.
    private func makeBox(size: NSSize) -> (panel: NSPanel, content: NSVisualEffectView) {
        let frame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true

        let effect = NSVisualEffectView(frame: frame)
        effect.autoresizingMask = [.width, .height]
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effect
        return (panel, effect)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let initial = NSSize(width: listWidth, height: rowHeight * CGFloat(maxVisibleRows))
        let (panel, effect) = makeBox(size: initial)

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(handleDoubleClick)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        column.width = listWidth
        table.addTableColumn(column)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 1, width: listWidth, height: initial.height - 2))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = true

        effect.addSubview(scroll)
        self.panel = panel
        self.tableView = table
        self.scrollView = scroll
        return panel
    }

    /// The detached documentation panel — its own window beside the list.
    private func ensureDocPanel() -> NSPanel {
        if let docPanel { return docPanel }
        let initial = NSSize(width: docWidth, height: minDocHeight)
        let (panel, effect) = makeBox(size: initial)

        let docScroll = NSScrollView(frame: NSRect(origin: .zero, size: initial))
        docScroll.autoresizingMask = [.width, .height]
        docScroll.drawsBackground = false
        docScroll.hasVerticalScroller = true
        docScroll.autohidesScrollers = true

        let docText = NSTextView(frame: NSRect(origin: .zero, size: initial))
        docText.isEditable = false
        docText.isSelectable = true
        docText.drawsBackground = false
        docText.textContainerInset = NSSize(width: 10, height: 10)
        docText.isVerticallyResizable = true
        docText.isHorizontallyResizable = false
        docText.autoresizingMask = [.width]
        docText.textContainer?.widthTracksTextView = true
        docScroll.documentView = docText

        effect.addSubview(docScroll)
        self.docPanel = panel
        self.docScrollView = docScroll
        self.docTextView = docText
        return panel
    }

    @objc private func handleDoubleClick() {
        onAccept?()
    }

    /// Invoked when the user double-clicks a row; the coordinator wires this to its
    /// accept path so mouse and keyboard accept go through the same splice.
    var onAccept: (() -> Void)?

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // AppKit can run a layout pass that asks for a row that no longer exists when
        // `items` shrank (or was cleared by hide()) before reloadData reconciled the
        // table — guard the subscript so that race can't trap.
        guard row >= 0, row < items.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("CompletionRow")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? CompletionRowView)
            ?? {
                let v = CompletionRowView()
                v.identifier = id
                return v
            }()
        cell.configure(with: items[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("CompletionRowBG")
        let view =
            (tableView.makeView(withIdentifier: id, owner: self) as? CompletionBackgroundRowView)
            ?? {
                let v = CompletionBackgroundRowView()
                v.identifier = id
                return v
            }()
        return view
    }
}

// MARK: - Row views

/// Rounded selection highlight that matches the menu look (vs. the default full-bleed
/// blue bar).
private final class CompletionBackgroundRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let inset = bounds.insetBy(dx: 4, dy: 1)
        let path = NSBezierPath(roundedRect: inset, xRadius: 5, yRadius: 5)
        NSColor.selectedContentBackgroundColor.setFill()
        path.fill()
    }

    override var isEmphasized: Bool {
        get { true } // keep the accent highlight even though the panel isn't key
        set {}
    }
}

private final class CompletionRowView: NSView {
    /// A leading gutter holds the "best match" star on the preselected row; reserving
    /// it on every row keeps the icon/label aligned whether or not the star shows.
    private let star = NSImageView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    private static let labelFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let matchFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        star.translatesAutoresizingMaskIntoConstraints = false
        star.imageScaling = .scaleProportionallyDown
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Best match")
        star.contentTintColor = .systemYellow
        star.toolTip = "Best match — inserted on Return/Tab"
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Self.labelFont
        label.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(star)
        addSubview(icon)
        addSubview(label)
        addSubview(detail)
        NSLayoutConstraint.activate([
            star.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            star.centerYAnchor.constraint(equalTo: centerYAnchor),
            star.widthAnchor.constraint(equalToConstant: 10),
            star.heightAnchor.constraint(equalToConstant: 10),
            icon.leadingAnchor.constraint(equalTo: star.trailingAnchor, constant: 5),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with item: CompletionItem) {
        // Bold + accent the characters that matched the typed prefix (IDE-style).
        let attributed = NSMutableAttributedString(
            string: item.label,
            attributes: [.font: Self.labelFont, .foregroundColor: NSColor.labelColor])
        let length = (item.label as NSString).length
        for range in item.matchedRanges {
            let ns = NSRange(location: range.location, length: range.length)
            guard ns.location >= 0, NSMaxRange(ns) <= length else { continue }
            attributed.addAttributes(
                [
                    .font: Self.matchFont,
                    .foregroundColor: NSColor.controlAccentColor,
                ], range: ns)
        }
        label.attributedStringValue = attributed

        detail.stringValue = item.detail ?? ""
        icon.image = NSImage(systemSymbolName: Self.symbolName(for: item.kind), accessibilityDescription: nil)
        icon.contentTintColor = Self.tint(for: item.kind)
        star.isHidden = !item.isPreselected
    }

    private static func symbolName(for kind: CompletionKind) -> String {
        switch kind {
        case .keyword: return "k.square.fill"
        case .value: return "textformat"
        case .enumCase: return "circle.grid.2x2"
        case .algorithm: return "lock.shield"
        case .host: return "server.rack"
        case .snippet: return "curlybraces"
        case .file: return "doc"
        case .folder: return "folder.fill"
        }
    }

    private static func tint(for kind: CompletionKind) -> NSColor {
        switch kind {
        case .keyword: return .controlAccentColor
        case .value, .enumCase: return .systemTeal
        case .algorithm: return .systemPurple
        case .host: return .systemGreen
        case .snippet: return .systemOrange
        case .file: return .systemGray
        case .folder: return .systemBlue
        }
    }
}
