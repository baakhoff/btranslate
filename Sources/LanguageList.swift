import Cocoa

/// A table row that names a language: "Russian" and, in grey, its own name "русский".
@MainActor
private func languageCell(in table: NSTableView, for target: Target) -> NSView {
    let id = NSUserInterfaceItemIdentifier("language")
    let cell: NSTableCellView
    if let reused = table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
        cell = reused
    } else {
        cell = NSTableCellView()
        cell.identifier = id
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
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

/// A popover with a search field over every language that is not in the list yet. A click on a
/// language (or Return, for the first one found) adds it; the popover stays open for more.
@MainActor
final class LanguagePicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let popover = NSPopover()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 330))
    var available: () -> [Target] = { [] }
    var onAdd: (Target) -> Void = { _ in }

    private let search = NSSearchField()
    private let table = NSTableView()
    private var shown: [Target] = []

    override init() {
        super.init()
        let size = view.frame.size
        search.placeholderString = "Search languages"
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

        let controller = NSViewController()
        controller.view = view
        popover.contentViewController = controller
        popover.contentSize = size
        popover.behavior = .transient  // a click outside closes it
    }

    func show(relativeTo rect: NSRect, of anchor: NSView) {
        setSearch("")
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
        view.window?.makeFirstResponder(search)
    }

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

/// The languages the popup's menu offers: a table with + and − under it. Rows can be dragged
/// into another order. At least one language stays.
@MainActor
final class LanguageListEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var languages: [Target] = [] {
        didSet {
            table.reloadData()
            refreshButtons()
        }
    }
    let view = NSStackView()
    let picker = LanguagePicker()

    private let table = NSTableView()
    private let buttons = NSSegmentedControl()
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

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 22 * 5 + 6).isActive = true  // five rows, then it scrolls

        buttons.segmentCount = 2
        buttons.trackingMode = .momentary
        buttons.segmentStyle = .smallSquare
        buttons.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
        buttons.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
        buttons.setWidth(28, forSegment: 0)
        buttons.setWidth(28, forSegment: 1)
        buttons.setToolTip("Add a language", forSegment: 0)
        buttons.setToolTip("Remove the selected languages", forSegment: 1)
        buttons.target = self
        buttons.action = #selector(buttonClicked)

        let note = NSTextField(labelWithString: "The popup's menu lists these. Drag to reorder.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let row = NSStackView(views: [buttons, note])
        row.spacing = 10

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        view.addArrangedSubview(scroll)
        view.addArrangedSubview(row)

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

    private func refreshButtons() {
        let selected = table.selectedRowIndexes.count
        buttons.setEnabled(selected > 0 && selected < languages.count, forSegment: 1)
    }

    @objc private func buttonClicked() {
        if buttons.selectedSegment == 0 {
            let plus = NSRect(x: 0, y: 0, width: buttons.bounds.width / 2, height: buttons.bounds.height)
            picker.show(relativeTo: plus, of: buttons)
        } else {
            let rows = table.selectedRowIndexes
            guard !rows.isEmpty, rows.count < languages.count else { return }
            languages = languages.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { languages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        languageCell(in: tableView, for: languages[row])
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
        dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let from = info.draggingPasteboard.string(forType: rowType).flatMap(Int.init),
              languages.indices.contains(from) else { return false }
        languages = moved(languages, from: from, to: row)
        return true
    }
}
