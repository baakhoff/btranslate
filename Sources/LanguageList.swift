import Cocoa

/// A table row that names a language: "Russian" and, in grey, its own name "русский"; the
/// default language of the list is marked as that.
@MainActor
private func languageCell(in table: NSTableView, for target: Target, isDefault: Bool = false) -> NSView {
    let id = NSUserInterfaceItemIdentifier("language")
    let cell: NSTableCellView
    if let reused = table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
        cell = reused
    } else {
        cell = NSTableCellView()
        cell.identifier = id
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
    }
    let text = NSMutableAttributedString(string: target.name, attributes: [.foregroundColor: NSColor.labelColor])
    if let own = target.ownName {
        text.append(NSAttributedString(string: "  " + own, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
    }
    if isDefault {
        text.append(NSAttributedString(string: "   ★ " + L("default"), attributes: [.foregroundColor: NSColor.controlAccentColor]))
    }
    let oneLine = NSMutableParagraphStyle()  // a long name is cut short, never wrapped into the next row
    oneLine.lineBreakMode = .byTruncatingTail
    text.addAttribute(.paragraphStyle, value: oneLine, range: NSRange(location: 0, length: text.length))
    cell.textField?.attributedStringValue = text
    return cell
}

/// `list` with the item at `from` moved so that it sits before what was at `to` (a table's drop row).
func moved<T>(_ list: [T], from: Int, to: Int) -> [T] {
    guard list.indices.contains(from), (0...list.count).contains(to) else { return list }
    var out = list
    let item = out.remove(at: from)
    out.insert(item, at: from < to ? to - 1 : to)
    return out
}

// MARK: - The "+" picker

/// A search field over a list of languages. A click on a language (or Return, for the first
/// one found) picks it. Settings shows it in a popover, to add languages to the list: it
/// stays open for more. The translation popup shows `view` in a panel of its own, to set the
/// original's language.
@MainActor
final class LanguagePicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 330))
    var available: () -> [Target] = { [] }    // the languages to offer
    var onAdd: (Target) -> Void = { _ in }    // one was picked

    private(set) lazy var popover: NSPopover = {
        let controller = NSViewController()
        controller.view = view
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = view.frame.size
        popover.behavior = .transient  // a click outside closes it
        return popover
    }()

    private let search = NSSearchField()
    private let table = NSTableView()
    private var shown: [Target] = []

    override init() {
        super.init()
        let size = view.frame.size
        search.placeholderString = L("Search languages")
        search.delegate = self
        search.frame = NSRect(x: 10, y: size.height - 34, width: size.width - 20, height: 24)
        search.autoresizingMask = [.width, .minYMargin]

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        column.width = size.width - 30
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - 44))
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view.addSubview(search)
        view.addSubview(scroll)
    }

    func show(relativeTo rect: NSRect, of anchor: NSView) {
        setSearch("")
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
        focusSearch()
    }

    /// Typing goes to the search field.
    func focusSearch() {
        view.window?.makeFirstResponder(search)
    }

    var searchHasFocus: Bool { view.window?.firstResponder === search.currentEditor() && search.currentEditor() != nil }

    func setSearch(_ text: String) {
        search.stringValue = text
        refresh()
    }

    private func refresh() {
        shown = searchTargets(search.stringValue, in: available())
        table.reloadData()
    }

    private func add(_ target: Target) {
        onAdd(target)
        refresh()  // the added language leaves this list
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), let first = shown.first else { return false }
        add(first)
        return true
    }

    @objc private func rowClicked() {
        if shown.indices.contains(table.clickedRow) { add(shown[table.clickedRow]) }
    }

    /// Adds the first language found, as Return in the search field does (UI test).
    func addFirstFound() {
        if let first = shown.first { add(first) }
    }

    var foundIDs: [String] { shown.map(\.id) }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        languageCell(in: tableView, for: shown[row])
    }
}

// MARK: - The list in Settings

/// The languages the popup offers: a table with + − ↑ ↓ and "Make Default" under it. Rows can
/// also be dragged into another order. One language is the default, the one a popup opens
/// with. At least one language stays.
@MainActor
final class LanguageListEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var languages: [Target] = [] {
        didSet {
            table.reloadData()
            refreshButtons()
        }
    }
    /// The default as it was chosen; `defaultLanguage` is what holds if it left the list.
    var defaultID = "" {
        didSet {
            table.reloadData()
            refreshButtons()
        }
    }
    var defaultLanguage: Target? { languages.first { $0.id == defaultID } ?? languages.first }

    let view = NSStackView()
    let picker = LanguagePicker()

    private let table = NSTableView()
    private let buttons = NSSegmentedControl()
    private let defaultButton = NSButton(title: L("Make Default"), target: nil, action: nil)
    private let rowType = NSPasteboard.PasteboardType("io.github.baakhoff.btranslate.language-row")

    init(width: CGFloat) {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        column.width = width - 24
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 22 * 5 + 6).isActive = true  // five rows, then it scrolls

        let images = [NSImage(named: NSImage.addTemplateName), NSImage(named: NSImage.removeTemplateName),
                      NSImage(systemSymbolName: "chevron.up", accessibilityDescription: L("Move up")),
                      NSImage(systemSymbolName: "chevron.down", accessibilityDescription: L("Move down"))]
        let tips = [L("Add a language"), L("Remove the selected languages"), L("Move the selected language up"), L("Move the selected language down")]
        buttons.segmentCount = images.count
        buttons.trackingMode = .momentary
        buttons.segmentStyle = .smallSquare
        for (i, image) in images.enumerated() {
            buttons.setImage(image, forSegment: i)
            buttons.setWidth(28, forSegment: i)
            buttons.setToolTip(tips[i], forSegment: i)
        }
        buttons.target = self
        buttons.action = #selector(buttonClicked)

        defaultButton.bezelStyle = .rounded
        defaultButton.controlSize = .small
        defaultButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        defaultButton.toolTip = L("A popup opens with the default language")
        defaultButton.target = self
        defaultButton.action = #selector(makeSelectedDefault)
        let row = NSStackView(views: [buttons, defaultButton])
        row.spacing = 10

        let note = NSTextField(wrappingLabelWithString:
            L("A popup opens with the default language; + in the popup adds others from this list. Use the arrows, or drag rows, to put them in your order."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: width).isActive = true

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        view.addArrangedSubview(scroll)
        view.addArrangedSubview(row)
        view.addArrangedSubview(note)

        picker.available = { [weak self] in
            let chosen = self?.languages ?? []
            return allTargets.filter { !chosen.contains($0) }
        }
        picker.onAdd = { [weak self] target in
            guard let self else { return }
            self.languages.append(target)
            self.table.scrollRowToVisible(self.languages.count - 1)
        }
    }

    /// The one selected row, if exactly one is.
    private var selectedRow: Int? {
        let rows = table.selectedRowIndexes
        return rows.count == 1 ? rows.first : nil
    }

    func select(row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        refreshButtons()
    }

    private func refreshButtons() {
        let selected = table.selectedRowIndexes.count
        buttons.setEnabled(selected > 0 && selected < languages.count, forSegment: 1)
        buttons.setEnabled(selectedRow.map { $0 > 0 } ?? false, forSegment: 2)
        buttons.setEnabled(selectedRow.map { $0 < languages.count - 1 } ?? false, forSegment: 3)
        defaultButton.isEnabled = selectedRow.map { languages[$0] != defaultLanguage } ?? false
    }

    @objc private func buttonClicked() {
        switch buttons.selectedSegment {
        case 0:
            let plus = NSRect(x: 0, y: 0, width: buttons.bounds.width / 4, height: buttons.bounds.height)
            picker.show(relativeTo: plus, of: buttons)
        case 1: removeSelected()
        case 2: moveSelected(by: -1)
        default: moveSelected(by: 1)
        }
    }

    func removeSelected() {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty, rows.count < languages.count else { return }
        languages = languages.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
    }

    /// Moves the selected language one place up (-1) or down (1); it stays selected.
    func moveSelected(by step: Int) {
        guard let row = selectedRow, languages.indices.contains(row + step) else { return }
        var list = languages
        list.swapAt(row, row + step)
        languages = list
        select(row: row + step)
        table.scrollRowToVisible(row + step)
    }

    @objc func makeSelectedDefault() {
        guard let row = selectedRow else { return }
        defaultID = languages[row].id
        select(row: row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { languages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        languageCell(in: tableView, for: languages[row], isDefault: languages[row] == defaultLanguage)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshButtons() }

    // Dragging a row to another place.

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Over a row the table proposes dropping "on" it: make that "before it", so a drop
        // anywhere in the list moves the row. (Without this only the thin gaps between rows took it.)
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let from = info.draggingPasteboard.string(forType: rowType).flatMap(Int.init),
              languages.indices.contains(from) else { return false }
        languages = moved(languages, from: from, to: row)
        select(row: from < row ? row - 1 : row)
        return true
    }
}
