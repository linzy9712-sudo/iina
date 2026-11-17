import Cocoa

extension NSPasteboard.PasteboardType { static let iinaNASMedia = Self("com.colliderli.iina.nas-media") }
enum NASDrop {
  static func entries(_ pasteboard: NSPasteboard) -> [NASQueueEntry]? {
    let blobs = (pasteboard.pasteboardItems ?? []).compactMap { $0.data(forType: .iinaNASMedia) }
    guard !blobs.isEmpty, blobs.reduce(0, { $0 + $1.count }) < 4_000_000 else { return nil }
    var entries: [NASQueueEntry] = []
    for data in blobs {
      guard let decoded = try? JSONDecoder().decode([NASQueueEntry].self, from: data),
            decoded.allSatisfy({ NASQueueEntry.decode($0.mpvPath) != nil }) else { return nil }
      entries += decoded
    }
    return entries
  }
}

/// Each column scrolls vertically itself. The outer scroll view only scrolls horizontally.
final class NASColumnsScrollView: NSScrollView {
  private var fittingDocument = false
  override func tile() {
    super.tile()
    guard !fittingDocument, let documentView else { return }
    let height = contentView.bounds.height
    guard abs(documentView.frame.height - height) > 0.5 else { return }
    fittingDocument = true
    documentView.setFrameSize(NSSize(width: documentView.frame.width, height: height))
    contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: 0))
    reflectScrolledClipView(contentView)
    fittingDocument = false
  }
}

final class NASBrowserWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
  private struct Row {
    var title: String
    var folder: String?
    var entry: NASQueueEntry?
  }
  private unowned let player: PlayerCore
  private let servers = NSPopUpButton()
  private let mode = NSPopUpButton()
  private let search = NSSearchField()
  private let table = NSTableView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private var configuration = NASConfiguration()
  private var rows: [Row] = []
  private var parents: [String?] = []
  private var folderNames: [String] = []
  private let breadcrumbs = NSStackView()
  private struct Location {
    var folder: String?
    var parents: [String?]
    var names: [String]
    var query: String
  }
  private var backHistory: [Location] = [], forwardHistory: [Location] = []
  private var location: Location { Location(folder: folder, parents: parents, names: folderNames, query: search.stringValue) }
  private let backButton = NSButton(), forwardButton = NSButton()
  private let viewStyle = NSSegmentedControl()
  private let listScroll = NSScrollView()
  private let columnsScroll = NASColumnsScrollView()
  private let columnsStack = NSStackView()
  private let content = NSView()
  private var columnRows: [[Row]] = []
  private var cachedRows: [String: [Row]] = [:]
  private weak var selectedTable: NSTableView?
  private var rebuildingColumns = false
  private var columnsVisible: Bool { viewStyle.selectedSegment == 1 && search.stringValue.isEmpty }
  private func rememberLocation() {
    backHistory.append(location); forwardHistory.removeAll()
    if backHistory.count > 100 { backHistory.removeFirst() }
  }
  private func restore(_ value: Location) {
    folder = value.folder; parents = value.parents; folderNames = value.names; search.stringValue = value.query
    refresh()
  }
  @objc private func goBack() {
    guard let previous = backHistory.popLast() else { return }
    forwardHistory.append(location); restore(previous)
  }
  @objc private func goForward() {
    guard let next = forwardHistory.popLast() else { return }
    backHistory.append(location); restore(next)
  }
  @objc private func changeView() {
    UserDefaults.standard.set(viewStyle.selectedSegment, forKey: "nasBrowserViewStyle")
    renderColumns()
  }
  private func data(for tableView: NSTableView) -> [Row] {
    tableView === table ? rows : (columnRows.indices.contains(tableView.tag) ? columnRows[tableView.tag] : [])
  }
  private func renderColumns() {
    rebuildingColumns = true
    defer { rebuildingColumns = false }
    backButton.isEnabled = !backHistory.isEmpty; forwardButton.isEnabled = !forwardHistory.isEmpty
    listScroll.isHidden = columnsVisible; columnsScroll.isHidden = !columnsVisible
    selectedTable = nil
    for view in columnsStack.arrangedSubviews { columnsStack.removeArrangedSubview(view); view.removeFromSuperview() }
    columnRows = []
    guard columnsVisible else { return }
    let locations = parents + [folder]
    for (depth, parent) in locations.enumerated() {
      let values = depth == parents.count ? rows : (cachedRows[parent ?? ""] ?? [])
      columnRows.append(values)
      let list = NSTableView(); list.tag = depth
      let column = NSTableColumn(identifier: .init("name")); column.width = 244
      column.title = depth == 0 ? NSLocalizedString("All folders", comment: "NAS") : folderNames[depth - 1]
      list.addTableColumn(column); list.delegate = self; list.dataSource = self
      list.allowsMultipleSelection = true; list.target = self
      list.action = #selector(columnClicked(_:)); list.doubleAction = #selector(columnDoubleClicked(_:))
      list.setDraggingSourceOperationMask(.copy, forLocal: true)
      list.menu = table.menu?.copy() as? NSMenu
      let scroll = NSScrollView(); scroll.documentView = list; scroll.hasVerticalScroller = true
      scroll.frame = NSRect(x: depth * 260, y: 0, width: 260, height: Int(columnsScroll.contentSize.height))
      columnsStack.addArrangedSubview(scroll)
      scroll.widthAnchor.constraint(equalToConstant: 260).isActive = true
      scroll.heightAnchor.constraint(equalTo: columnsStack.heightAnchor).isActive = true
      if depth < parents.count {
        let next = depth + 1 < parents.count ? parents[depth + 1] : folder
        if let index = values.firstIndex(where: { $0.folder == next }) {
          list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
          // Navigation rebuilds every table. Keep the deepest selected folder as the append source.
          if depth == parents.count - 1 { selectedTable = list }
        }
      }
    }
    columnsStack.setFrameSize(NSSize(width: CGFloat(locations.count) * 260, height: columnsScroll.contentSize.height))
    columnsScroll.contentView.scroll(to: NSPoint(x: max(0, columnsStack.frame.width - columnsScroll.contentSize.width), y: 0))
    columnsScroll.reflectScrolledClipView(columnsScroll.contentView)
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !rebuildingColumns, let table = notification.object as? NSTableView else { return }
    selectedTable = table
  }
  @objc private func columnClicked(_ sender: NSTableView) {
    selectedTable = sender
    let values = data(for: sender)
    guard values.indices.contains(sender.clickedRow), sender.selectedRowIndexes.count == 1,
          !NSEvent.modifierFlags.contains(.command), !NSEvent.modifierFlags.contains(.shift),
          let next = values[sender.clickedRow].folder else { return }
    let depth = sender.tag
    let existing = depth + 1 < parents.count ? parents[depth + 1] : (depth < parents.count ? folder : nil)
    guard next != existing else { return }
    rememberLocation()
    let parent = depth < parents.count ? parents[depth] : folder
    parents = Array(parents.prefix(depth)) + [parent]
    folderNames = Array(folderNames.prefix(depth)) + [values[sender.clickedRow].title]
    folder = next; search.stringValue = ""; refresh()
  }
  @objc private func columnDoubleClicked(_ sender: NSTableView) {
    let values = data(for: sender)
    guard values.indices.contains(sender.clickedRow), let entry = values[sender.clickedRow].entry else { return }
    player.nas.append([entry], play: true)
  }
  private func updateBreadcrumbs() {
    for view in breadcrumbs.arrangedSubviews { breadcrumbs.removeArrangedSubview(view); view.removeFromSuperview() }
    let titles = [NSLocalizedString("All folders", comment: "NAS")] + folderNames
    func separator() {
      if !breadcrumbs.arrangedSubviews.isEmpty { breadcrumbs.addArrangedSubview(NSTextField(labelWithString: "›")) }
    }
    func addFolder(_ depth: Int) {
      separator()
      let button = NSButton(title: titles[depth], target: self, action: #selector(jumpToFolder(_:)))
      button.tag = depth; button.bezelStyle = .rounded
      button.toolTip = titles[depth]
      button.cell?.lineBreakMode = .byTruncatingMiddle
      button.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
      button.isEnabled = depth != folderNames.count
      breadcrumbs.addArrangedSubview(button)
    }
    addFolder(0)
    if titles.count > 3 {
      separator()
      let overflow = NSPopUpButton(frame: .zero, pullsDown: true)
      overflow.addItem(withTitle: "…")
      overflow.toolTip = NSLocalizedString("Parent folders", comment: "NAS")
      for depth in 1..<(titles.count - 2) {
        let item = NSMenuItem(title: titles[depth], action: #selector(jumpToFolder(_:)), keyEquivalent: "")
        item.target = self; item.tag = depth
        overflow.menu?.addItem(item)
      }
      breadcrumbs.addArrangedSubview(overflow)
    }
    for depth in max(1, titles.count - 2)..<titles.count { addFolder(depth) }
  }
  @objc private func jumpToFolder(_ sender: Any) {
    let depth = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? -1
    guard depth >= 0, depth < parents.count else { return }
    rememberLocation()
    folder = parents[depth]
    parents = Array(parents.prefix(depth)); folderNames = Array(folderNames.prefix(depth))
    search.stringValue = ""; refresh()
  }
  private func navigate(to row: Row) {
    guard let next = row.folder, next != folder else { return }
    rememberLocation()
    parents.append(folder); folderNames.append(row.title)
    folder = next; search.stringValue = ""; refresh()
  }
  @objc private func enterFolder(_ sender: NSButton) {
    guard rows.indices.contains(sender.tag) else { return }
    navigate(to: rows[sender.tag])
  }
  private var folder: String?
  private var task: Task<Void, Never>?
  private var ticket = UUID()
  private var importTask: Task<Void, Never>?
  private var importTicket = UUID()

  init(player: PlayerCore) {
    self.player = player
    super.init(window: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  private var server: NASServer? {
    configuration.servers.indices.contains(servers.indexOfSelectedItem) ? configuration.servers[servers.indexOfSelectedItem] : nil
  }
  override func loadWindow() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "NAS / Jellyfin"; window.isReleasedWhenClosed = false; window.delegate = self
    let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
    backButton.title = "‹"; backButton.target = self; backButton.action = #selector(goBack)
    forwardButton.title = "›"; forwardButton.target = self; forwardButton.action = #selector(goForward)
    backButton.toolTip = NSLocalizedString("Back", comment: "NAS"); forwardButton.toolTip = NSLocalizedString("Forward", comment: "NAS")
    backButton.bezelStyle = .rounded; forwardButton.bezelStyle = .rounded
    viewStyle.segmentCount = 2
    viewStyle.setLabel(NSLocalizedString("List view", comment: "NAS"), forSegment: 0)
    viewStyle.setLabel(NSLocalizedString("Column view", comment: "NAS"), forSegment: 1)
    viewStyle.selectedSegment = UserDefaults.standard.object(forKey: "nasBrowserViewStyle") == nil ? 1 : min(1, max(0, UserDefaults.standard.integer(forKey: "nasBrowserViewStyle")))
    viewStyle.target = self; viewStyle.action = #selector(changeView)
    let top = NSStackView(views: [backButton, forwardButton, servers, mode, button("Up", #selector(up)), button("Refresh", #selector(refresh))])
    let viewBar = NSStackView(views: [viewStyle, button("Append current folder", #selector(appendCurrentFolder))])
    mode.addItems(withTitles: ["Jellyfin libraries", "Indexed physical folders"].map { NSLocalizedString($0, comment: "NAS") })
    mode.target = self; mode.action = #selector(resetFolder)
    servers.target = self; servers.action = #selector(resetFolder)
    search.placeholderString = NSLocalizedString("Search videos", comment: "NAS"); search.target = self; search.action = #selector(refresh)
    listScroll.documentView = table; listScroll.hasVerticalScroller = true
    columnsStack.orientation = .horizontal; columnsStack.spacing = 0; columnsStack.alignment = .top
    columnsScroll.documentView = columnsStack; columnsScroll.hasHorizontalScroller = true
    columnsScroll.hasVerticalScroller = false
    columnsScroll.automaticallyAdjustsContentInsets = false
    columnsScroll.horizontalScrollElasticity = .none
    columnsScroll.verticalScrollElasticity = .none
    for scroll in [listScroll, columnsScroll] {
      content.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
    }
    let column = NSTableColumn(identifier: .init("name")); column.title = NSLocalizedString("Folder / Video", comment: "NAS"); column.width = 650
    table.addTableColumn(column); table.delegate = self; table.dataSource = self
    table.allowsMultipleSelection = true; table.target = self; table.doubleAction = #selector(openSelection)
    table.setDraggingSourceOperationMask(.copy, forLocal: true)
    let menu = NSMenu(); let add = NSMenuItem(title: "Append selected (including subfolders)", action: #selector(appendSelection), keyEquivalent: ""); add.target = self; menu.addItem(add); table.menu = menu
    let actions = NSStackView(views: [button("Append selected", #selector(appendSelection)), button("Saved playlists", #selector(saved)), button("Audio / Subtitles", #selector(tracks)), button("Import results", #selector(importResults)), button("Cancel", #selector(cancel))])
    breadcrumbs.orientation = .horizontal; breadcrumbs.spacing = 4
    breadcrumbs.distribution = .gravityAreas
    breadcrumbs.heightAnchor.constraint(equalToConstant: 30).isActive = true
    window.contentMinSize = NSSize(width: 600, height: 420)
    [top, viewBar, breadcrumbs, search, content, actions, status].forEach { view in
      stack.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    let host = NSView(); host.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12), content.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)])
    window.contentView = host; self.window = window; window.center()
    do {
      configuration = try NASPlayerCoordinator.store.load()
      servers.addItems(withTitles: configuration.servers.map(\.name))
      refresh()
    } catch { status.stringValue = error.localizedDescription }
  }
  override func showWindow(_ sender: Any?) {
    // init(window: nil) does not trigger loadWindow through the window getter.
    if window == nil { loadWindow() }
    let old = server?.id
    do {
      configuration = try NASPlayerCoordinator.store.load()
      servers.removeAllItems(); servers.addItems(withTitles: configuration.servers.map(\.name))
      if let index = configuration.servers.firstIndex(where: { $0.id == old }) { servers.selectItem(at: index) }
      resetFolder()
    } catch { status.stringValue = error.localizedDescription }
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
  }
  func windowWillClose(_ notification: Notification) { task?.cancel(); ticket = UUID(); cancelImport() }
  private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: NSLocalizedString(title, comment: "NAS"), target: self, action: action) }
  func numberOfRows(in tableView: NSTableView) -> Int { data(for: tableView).count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let rows = data(for: tableView)
    guard rows.indices.contains(row) else { return nil }
    if tableView === table, rows[row].folder != nil {
      let folderButton = NSButton(title: "📁 " + rows[row].title, target: self, action: #selector(enterFolder(_:)))
      folderButton.isBordered = false; folderButton.alignment = .left; folderButton.tag = row
      return folderButton
    }
    let label = NSTextField(labelWithString: (rows[row].folder == nil ? "" : "📁 ") + rows[row].title)
    label.lineBreakMode = .byTruncatingMiddle; label.toolTip = rows[row].title
    return label
  }
  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
    let rows = data(for: tableView)
    guard rows.indices.contains(row), let entry = rows[row].entry, let data = try? JSONEncoder().encode([entry]) else { return nil }
    let item = NSPasteboardItem(); item.setData(data, forType: .iinaNASMedia); return item
  }
  private func cancelImport() { importTask?.cancel(); importTask = nil; importTicket = UUID() }
  @objc private func cancel() { player.folderPlaylistImporter.cancel(); task?.cancel(); ticket = UUID(); cancelImport(); status.stringValue = "Cancelled" }
  @objc private func tracks() { player.nas.showTracks() }
  @objc private func saved() { player.nas.showLibrary() }
  @objc private func importResults() {
    let alert = NSAlert(); alert.messageText = "NAS diagnostics"
    alert.informativeText = ([player.nas.diagnostic] + player.nas.importErrors).filter { !$0.isEmpty }.joined(separator: "\n")
    if alert.informativeText.isEmpty { alert.informativeText = "No import errors." }
    if let window { alert.beginSheetModal(for: window) }
  }
  @objc private func resetFolder() { cancelImport(); cachedRows.removeAll(); backHistory.removeAll(); forwardHistory.removeAll(); folder = nil; parents = []; folderNames = []; search.stringValue = ""; refresh() }
  @objc private func up() { guard !parents.isEmpty else { return }; rememberLocation(); folder = parents.removeLast(); folderNames.removeLast(); search.stringValue = ""; refresh() }
  @objc private func refresh() {
    updateBreadcrumbs()
    task?.cancel(); ticket = UUID(); let stamp = ticket
    guard let server else { status.stringValue = "Add and sign in to a server in Settings → NAS / Jellyfin."; return }
    let physical = mode.indexOfSelectedItem == 1, folder = self.folder, query = search.stringValue
    rows = []; table.reloadData(); renderColumns() // Old rows must not accept a second click during navigation.
    status.stringValue = NSLocalizedString("Loading…", comment: "NAS")
    task = Task { @MainActor in
      do {
        let result: [Row]
        if physical {
          let index = try await Task.detached { try NASPlayerCoordinator.store.index(for: server) }.value
          let prefix = (folder ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
          let root = prefix.isEmpty ? "/" : "/" + prefix + "/"
          var directories = Set<String>(), values: [Row] = []
          for media in index.media where media.path.hasPrefix(root) {
            let tail = String(media.path.dropFirst(root.count))
            if !query.isEmpty {
              if media.title.localizedCaseInsensitiveContains(query) || tail.localizedCaseInsensitiveContains(query) { values.append(Row(title: tail, entry: .remote(media, server: server))) }
            } else if let slash = tail.firstIndex(of: "/") {
              directories.insert(String(tail[..<slash]))
            } else { values.append(Row(title: tail, entry: .remote(media, server: server))) }
          }
          result = directories.map { Row(title: $0, folder: root + $0) } + values
        } else {
          let items = try await fetch(server: server, parent: folder, recursive: !query.isEmpty, query: query)
          result = items.map { item in
            item.IsFolder == true ? Row(title: item.Name ?? item.Id, folder: item.Id) : Row(title: item.Name ?? item.Id, entry: NASQueueEntry(title: item.Name ?? item.Id, server: server.id, serverID: server.serverID, itemID: item.Id))
          }
        }
        guard ticket == stamp, !Task.isCancelled else { return }
        rows = result.sorted { a, b in
          if (a.folder != nil) != (b.folder != nil) { return a.folder != nil }
          return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        if query.isEmpty { cachedRows[folder ?? ""] = rows }
        table.reloadData(); renderColumns(); status.stringValue = String(format: NSLocalizedString("%d items", comment: "NAS"), rows.count) + (physical ? NSLocalizedString(" · Cached index", comment: "NAS") : "")
      } catch { if ticket == stamp { status.stringValue = error.localizedDescription } }
    }
  }
  private func fetch(server: NASServer, parent: String?, recursive: Bool, query: String = "") async throws -> [JellyfinClient.Item] {
    let token = try await Task.detached { try JellyfinCredentialStore().read(server) }.value
    let client = JellyfinClient(deviceID: configuration.deviceID)
    var result: [JellyfinClient.Item] = [], seen = Set<String>()
    while true {
      try Task.checkCancellation()
      var parameters = [URLQueryItem(name: "UserId", value: server.userID), URLQueryItem(name: "StartIndex", value: String(result.count)), URLQueryItem(name: "Limit", value: "500"), URLQueryItem(name: "Recursive", value: recursive ? "true" : "false"), URLQueryItem(name: "Fields", value: "Path,MediaSources,ParentId"), URLQueryItem(name: "SortBy", value: "SortName")]
      if let parent { parameters.append(URLQueryItem(name: "ParentId", value: parent)) }
      if recursive { parameters.append(URLQueryItem(name: "MediaTypes", value: "Video")) }
      if !query.isEmpty { parameters.append(URLQueryItem(name: "SearchTerm", value: query)) }
      let path = parent == nil && !recursive ? "Users/\(server.userID ?? "")/Views" : "Items"
      let page: JellyfinClient.Page = try await client.request(server.baseURL, path: path, token: token, query: parameters)
      for item in page.Items { guard seen.insert(item.Id).inserted else { throw NASError.invalidResponse }; result.append(item) }
      if result.count >= page.TotalRecordCount { break }
      if page.Items.isEmpty { throw NASError.invalidResponse }
    }
    return result.filter { $0.IsFolder == true || $0.MediaType == "Video" || $0.Path != nil }
  }
  @objc private func openSelection() {
    guard table.clickedRow >= 0, rows.indices.contains(table.clickedRow) else { return }
    let row = rows[table.clickedRow]
    if row.folder != nil { navigate(to: row) }
    else if let entry = row.entry { player.nas.append([entry], play: true) }
  }
  private func selectedRowsForAppend() -> [Row] {
    guard let source = columnsVisible ? selectedTable : table else { return [] }
    let values = data(for: source)
    return source.selectedRowIndexes.compactMap { values.indices.contains($0) ? values[$0] : nil }
  }
  @objc private func appendSelection() {
    appendRows(selectedRowsForAppend())
  }
  @objc private func appendCurrentFolder() {
    guard let folder else {
      status.stringValue = NSLocalizedString("Open a folder first.", comment: "NAS")
      return
    }
    appendRows([Row(title: folderNames.last ?? folder, folder: folder)])
  }
  private func appendRows(_ selected: [Row]) {
    guard let server else { return }
    guard !selected.isEmpty else {
      status.stringValue = NSLocalizedString("Select videos or a folder to add.", comment: "NAS")
      return
    }
    guard importTask == nil else {
      status.stringValue = NSLocalizedString("Adding videos… Please wait or cancel the current import.", comment: "NAS")
      return
    }
    let physical = mode.indexOfSelectedItem == 1
    importTicket = UUID(); let stamp = importTicket
    status.stringValue = "Collecting selected folders…"
    importTask = Task { @MainActor in
      defer { if importTicket == stamp { importTask = nil } }
      do {
        var entries: [NASQueueEntry] = []
        for row in selected {
          try Task.checkCancellation()
          if let entry = row.entry { entries.append(entry) }
          else if let folder = row.folder {
            if physical {
              let index = try await Task.detached { try NASPlayerCoordinator.store.index(for: server) }.value
              entries += index.media.filter { $0.path.hasPrefix(folder + "/") }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.map { .remote($0, server: server) }
            } else {
              let items = try await fetch(server: server, parent: folder, recursive: true)
              entries += items.filter { $0.IsFolder != true }.map { NASQueueEntry(title: $0.Name ?? $0.Id, server: server.id, serverID: server.serverID, itemID: $0.Id) }
            }
          }
        }
        guard importTicket == stamp, !Task.isCancelled else { return }
        player.nas.append(entries); status.stringValue = "Processed \(entries.count) videos."
      } catch { if importTicket == stamp { status.stringValue = error.localizedDescription } }
    }
  }
}
