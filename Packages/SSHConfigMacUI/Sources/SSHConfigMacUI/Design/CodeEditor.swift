//
//  CodeEditor.swift
//  sshconfigmanager
//
//  A real code surface for raw ssh_config text — an NSTextView wrapped for SwiftUI
//  so it can do the things `TextEditor` can't: a line-number gutter, a configurable
//  monospaced font, an explicit tab width, soft-wrap toggling, and lightweight
//  ssh_config syntax highlighting. All of those are driven by `AppSettings`, passed
//  in by the parent view (which observes the settings), so flipping a preference
//  reconfigures the live editor.
//
//  Highlighting is intentionally a single-pass line scanner, not a grammar: comments
//  dim, the leading keyword of a directive takes the accent, the value stays primary.
//  That's enough to make a config readable without the cost (or fragility) of a real
//  tokenizer, and it re-runs cheaply on each edit because a config file is small.
//

import AppKit
import SSHConfigIntelliSense
import SwiftUI

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true

    // Driven by AppSettings (the parent passes the current values so updates flow).
    var fontName: String = ""
    var fontSize: Double = 12
    var tabWidth: Int = 4
    var showLineNumbers: Bool = true
    var softWrap: Bool = false
    var highlight: Bool = true
    var intelliSense: Bool = false
    /// Show the detached documentation panel beside the completion list.
    var showDocs: Bool = true
    /// Optional sandbox-confined directory lister that powers file-path completion for
    /// path-typed keywords (IdentityFile, …). `nil` ⇒ no filesystem suggestions.
    var fileSystem: FileSystemBrowsing? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Called when SwiftUI removes the editor from the hierarchy (e.g. the user
    /// navigates to a different sidebar section). Hide the popup immediately — the
    /// NSPanel is a child-window that survives the host view being torn down otherwise.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor

        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true

        textView.string = text
        configure(textView, scrollView: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        // Replace text only when it actually differs, so we don't fight the cursor.
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            // The old selection was built against the *old* string — restoring it
            // verbatim against a shorter new one raises NSRangeException (audit
            // #31: currently unreachable since both call sites bind only a local
            // @State the editor itself mutates, but an external mutation binding
            // — a revert, a file-watch merge — would hit this the moment it lands).
            textView.selectedRanges = Self.clampSelectedRanges(
                selected, toLength: (text as NSString).length)
            // Undo steps recorded against the old string are meaningless (and
            // exception-prone to replay) against the one that just replaced it.
            textView.undoManager?.removeAllActions()
            context.coordinator.completion.hide() // stale popup after an external edit
        }
        configure(textView, scrollView: scrollView, coordinator: context.coordinator)
        // Wire up the first-responder observer once the view is attached to a window.
        // This catches sidebar clicks that move focus without changing the text selection.
        if let window = scrollView.window {
            context.coordinator.startObservingFirstResponder(in: window)
        }
    }

    /// Applies every preference and re-highlights. Idempotent — safe to call on each
    /// `updateNSView`.
    private func configure(_ textView: NSTextView, scrollView: NSScrollView, coordinator: Coordinator) {
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.setAccessibilityIdentifier("raw-editor") // UI-test / demo hook

        let font = Self.resolveFont(name: fontName, size: fontSize)
        coordinator.font = font

        // Tab width via a default paragraph style with no fixed tab stops and a tab
        // interval of N glyph-widths.
        let charWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = charWidth * CGFloat(max(1, tabWidth))
        coordinator.paragraphStyle = style
        textView.defaultParagraphStyle = style
        textView.font = font
        textView.typingAttributes = [
            .font: font,
            .paragraphStyle: style,
            .foregroundColor: NSColor.textColor,
        ]

        // Soft wrap vs. horizontal scrolling.
        if let container = textView.textContainer {
            if softWrap {
                scrollView.hasHorizontalScroller = false
                textView.isHorizontallyResizable = false
                container.widthTracksTextView = true
                container.containerSize = NSSize(
                    width: scrollView.contentSize.width,
                    height: .greatestFiniteMagnitude)
            } else {
                scrollView.hasHorizontalScroller = true
                textView.isHorizontallyResizable = true
                container.widthTracksTextView = false
                container.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude)
                textView.maxSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude)
            }
        }

        scrollView.rulersVisible = showLineNumbers
        if let ruler = scrollView.verticalRulerView as? LineNumberRulerView {
            ruler.font = NSFont.monospacedDigitSystemFont(ofSize: max(9, fontSize - 2), weight: .regular)
            ruler.needsDisplay = true
        }

        coordinator.applyHighlighting(to: textView, enabled: highlight)
    }

    /// The configured monospaced font, falling back to the system monospaced font when
    /// the name is empty or unresolvable.
    static func resolveFont(name: String, size: Double) -> NSFont {
        let pt = CGFloat(size)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let font = NSFont(name: trimmed, size: pt) { return font }
        return NSFont.monospacedSystemFont(ofSize: pt, weight: .regular)
    }

    /// Clamps each range in `ranges` (boxed `NSValue`s, matching
    /// `NSTextView.selectedRanges`'s own type) so none extends past `length`
    /// (audit #31). Restoring a selection built against an *old* string
    /// verbatim onto a *shorter* new one is exactly what
    /// `NSTextView.setSelectedRanges` raises `NSRangeException` for — this is
    /// the pure, unit-testable half of that fix.
    nonisolated static func clampSelectedRanges(_ ranges: [NSValue], toLength length: Int) -> [NSValue] {
        ranges.map { value in
            let range = value.rangeValue
            let location = min(range.location, length)
            let clampedLength = min(range.length, length - location)
            return NSValue(range: NSRange(location: location, length: clampedLength))
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
        var paragraphStyle = NSParagraphStyle.default

        // IntelliSense: the (stateless) engine, the popup, and the document span the
        // popup is currently completing — used to dismiss it the moment the caret
        // leaves that token.
        let completion = CompletionController()
        private let engine = IntelliSenseEngine()
        private var activeReplace: ReplacementRange?

        // KVO token watching the host window's first-responder. Detects sidebar clicks
        // that move focus away from the text view without a selection-change event.
        private var firstResponderObservation: NSKeyValueObservation?

        init(_ parent: CodeEditor) {
            self.parent = parent
            super.init()
            completion.onAccept = { [weak self] in
                guard let self, let textView = self.completionTextView else { return }
                self.acceptSelected(in: textView)
            }
        }

        /// Start (or re-use an existing) KVO observation on the window's firstResponder.
        /// Guards against duplicate observations — safe to call from every updateNSView.
        func startObservingFirstResponder(in window: NSWindow) {
            guard firstResponderObservation == nil else { return }
            firstResponderObservation = window.observe(\.firstResponder, options: [.new]) {
                [weak self] _, change in
                let focusLeftEditor = !(change.newValue is NSTextView)
                MainActor.assumeIsolated {
                    guard let self, self.completion.isVisible, focusLeftEditor else { return }
                    self.completion.hide()
                    self.activeReplace = nil
                }
            }
        }

        /// Called by dismantleNSView — cancel the KVO and hide the popup before the
        /// host view is removed from the hierarchy.
        func tearDown() {
            firstResponderObservation = nil
            completion.hide()
            activeReplace = nil
        }

        /// The text view we last drove completion for, so the double-click handler can
        /// splice into it.
        private weak var completionTextView: NSTextView?

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            applyHighlighting(to: textView, enabled: parent.highlight)
            if parent.intelliSense {
                refreshCompletions(in: textView)
            } else {
                completion.hide()
            }
        }

        // MARK: - IntelliSense driving

        /// Recompute completions at the caret and show / refresh / hide the popup.
        func refreshCompletions(in textView: NSTextView) {
            completionTextView = textView
            let sel = textView.selectedRange()
            // Only complete a collapsed caret, never over a selection.
            guard sel.length == 0 else {
                activeReplace = nil
                completion.hide()
                return
            }

            let items = engine.completions(
                in: textView.string, utf16CursorOffset: sel.location,
                fileSystem: parent.fileSystem)
            guard !items.isEmpty else {
                activeReplace = nil
                completion.hide()
                return
            }

            activeReplace = items[0].replace
            let anchor = NSRange(location: items[0].replace.location, length: 0)
            let rect = textView.firstRect(forCharacterRange: anchor, actualRange: nil)
            completion.documentationEnabled = parent.showDocs
            completion.show(items: items, anchoredTo: rect, in: textView.window)
        }

        /// Splice the highlighted item into the document (shared by Return/Tab and
        /// double-click), routed through the undo-aware text-change machinery.
        @discardableResult
        func acceptSelected(in textView: NSTextView) -> Bool {
            guard let item = completion.selectedItem else { return false }
            let range = NSRange(location: item.replace.location, length: item.replace.length)
            if textView.shouldChangeText(in: range, replacementString: item.insertText) {
                textView.textStorage?.replaceCharacters(in: range, with: item.insertText)
                textView.didChangeText()
                let caret = item.replace.location + (item.insertText as NSString).length
                textView.setSelectedRange(NSRange(location: caret, length: 0))
            }
            // Accepting a folder drills in: the inserted "dir/" lands the caret on a
            // fresh path segment, so re-run completion to list its contents instead of
            // dismissing (IDE-style traversal). Everything else commits and closes.
            if item.kind == .folder, parent.intelliSense {
                refreshCompletions(in: textView)
            } else {
                completion.hide()
                activeReplace = nil
            }
            return true
        }

        /// Dismiss the popup when the caret moves out of the token being completed
        /// (clicking elsewhere, arrowing left/right past the token, etc.). Typing keeps
        /// it up because `textDidChange` re-shows it with a fresh `activeReplace` first.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard completion.isVisible, let region = activeReplace,
                let textView = notification.object as? NSTextView
            else { return }
            let caret = textView.selectedRange().location
            if caret < region.location || caret > region.location + region.length {
                completion.hide()
                activeReplace = nil
            }
        }

        /// Intercept navigation / commit / dismiss keys while the popup is up so they
        /// drive the popup instead of the text view. Everything else falls through.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Ctrl-Space style explicit trigger, even with the popup hidden.
            if commandSelector == #selector(NSResponder.complete(_:)), parent.intelliSense {
                refreshCompletions(in: textView)
                return true
            }
            guard completion.isVisible else { return false }

            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                completion.moveSelection(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                completion.moveSelection(by: 1)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                #selector(NSResponder.insertTab(_:)),
                #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                return acceptSelected(in: textView)
            case #selector(NSResponder.cancelOperation(_:)):
                completion.hide()
                activeReplace = nil
                return true
            default:
                return false
            }
        }

        /// Paints the whole document: base attributes everywhere, then comment / keyword
        /// accents when highlighting is on.
        func applyHighlighting(to textView: NSTextView, enabled: Bool) {
            guard let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: (storage.string as NSString).length)
            storage.beginEditing()
            storage.setAttributes(
                [
                    .font: font,
                    .paragraphStyle: paragraphStyle,
                    .foregroundColor: NSColor.textColor,
                ], range: full)

            if enabled {
                let nsString = storage.string as NSString
                nsString.enumerateSubstrings(in: full, options: .byLines) { _, lineRange, _, _ in
                    Self.highlightLine(nsString, lineRange: lineRange, storage: storage)
                }
            }
            storage.endEditing()
        }

        /// Comment lines dim entirely; directive lines tint just the leading keyword.
        private static func highlightLine(_ nsString: NSString, lineRange: NSRange, storage: NSTextStorage) {
            // Skip leading whitespace.
            var i = lineRange.location
            let end = lineRange.location + lineRange.length
            while i < end {
                let c = nsString.character(at: i)
                if c != 0x20 && c != 0x09 { break } // space / tab
                i += 1
            }
            guard i < end else { return }

            if nsString.character(at: i) == UInt16(UInt8(ascii: "#")) {
                storage.addAttribute(
                    .foregroundColor, value: NSColor.secondaryLabelColor,
                    range: NSRange(
                        location: lineRange.location,
                        length: lineRange.length))
                return
            }

            // Keyword = run up to the first whitespace or '='.
            var k = i
            while k < end {
                let c = nsString.character(at: k)
                if c == 0x20 || c == 0x09 || c == UInt16(UInt8(ascii: "=")) { break }
                k += 1
            }
            if k > i {
                storage.addAttribute(
                    .foregroundColor, value: NSColor.controlAccentColor,
                    range: NSRange(location: i, length: k - i))
            }
        }
    }
}

// MARK: - Line number gutter

/// A minimal line-number ruler. It walks the layout manager's line fragments in the
/// visible rect and draws each line's number, so it stays correct under soft wrap
/// (wrapped continuation rows get no number) and scrolling.
final class LineNumberRulerView: NSRulerView {
    var font: NSFont = .monospacedDigitSystemFont(ofSize: 10, weight: .regular) {
        didSet { needsDisplay = true }
    }

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 38
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else { return }

        let content = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let inset = textView.textContainerInset.height
        let yOffset = convert(NSPoint.zero, from: textView).y

        // Count newlines before the first visible glyph to seed the line number.
        let firstCharIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        var lineNumber = 1 + numberOfNewlines(in: content, upTo: firstCharIndex)

        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var effectiveRange = NSRange(location: 0, length: 0)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &effectiveRange)
            // Only number the *first* fragment of each logical line (skip soft-wrapped
            // continuations).
            let charIndex = layoutManager.characterIndexForGlyph(at: effectiveRange.location)
            let isLineStart = charIndex == 0 || content.character(at: charIndex - 1) == UInt16(UInt8(ascii: "\n"))

            if isLineStart {
                let y = lineRect.minY + inset + yOffset
                let label = "\(lineNumber)" as NSString
                let size = label.size(withAttributes: attributes)
                let drawRect = NSRect(
                    x: ruleThickness - size.width - 5,
                    y: y + (lineRect.height - size.height) / 2,
                    width: size.width, height: size.height)
                label.draw(in: drawRect, withAttributes: attributes)
                lineNumber += 1
            }
            glyphIndex = NSMaxRange(effectiveRange)
        }
    }

    private func numberOfNewlines(in string: NSString, upTo index: Int) -> Int {
        guard index > 0 else { return 0 }
        let newline = UInt16(UInt8(ascii: "\n"))
        var count = 0
        for i in 0..<min(index, string.length) where string.character(at: i) == newline {
            count += 1
        }
        return count
    }
}
