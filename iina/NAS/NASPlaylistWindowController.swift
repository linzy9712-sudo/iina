import Cocoa

final class NASPlaylistWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
  private unowned let player: PlayerCore
  private let lists = NSTableView(), entries = NSTableView()
  private let status = NSTextField(wrappingLabelWithString: "")
  private var archive = NASPlaylistArchive()
  private var url: URL { NASPlayerCoordinator.store.directory.appendingPathComponent("playlists.json") }
  init(player: PlayerCore) { self.player = player; super.init(window: nil) }
  required init?(coder: NSCoder) { fatalError() }
  override func loadWindow() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Saved playlists"; window.isReleasedWhenClosed = false
    let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
    let tables = NSStackView(); tables.distribution = .fillEqually
    for (table, title) in [(lists, "Playlists"), (entries, "Videos")] {
      let col = NSTableColumn(identifier: .init(title)); col.title = title; col.width = 330; table.addTableColumn(col)
      table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = true
      let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table; tables.addArrangedSubview(scroll)
    }
    let controls = NSStackView(views: [button("Save current", #selector(saveCurrent)), button("Rename", #selector(rename)), button("Copy", #selector(copyList)), button("Merge", #selector(merge)), button("Delete", #selector(deleteList)), button("Append selected videos", #selector(appendSelection))])
    for view in [tables, controls, status] { root.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    let host = NSView(); host.addSubview(root); root.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12), root.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12), root.topAnchor.constraint(equalTo: host.topAnchor, constant: 12), root.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12), tables.heightAnchor.constraint(greaterThanOrEqualToConstant: 250)])
    self.window = window; window.contentView = host; window.center()
    do { archive = try NASPlaylistArchive.read(url) } catch { status.stringValue = error.localizedDescription; controls.subviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = false } }
    lists.reloadData()
  }
  override func showWindow(_ sender: Any?) {
    // init(window: nil) does not trigger loadWindow through the window getter.
    if window == nil { loadWindow() }
    do { archive = try NASPlaylistArchive.read(url); lists.reloadData(); entries.reloadData() }
    catch { status.stringValue = error.localizedDescription }
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
  }
  private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: NSLocalizedString(title, comment: "NAS"), target: self, action: action) }
  private var selected: NASSavedPlaylist? { archive.playlists.indices.contains(lists.selectedRow) ? archive.playlists[lists.selectedRow] : nil }
  func numberOfRows(in tableView: NSTableView) -> Int { tableView === lists ? archive.playlists.count : selected?.entries.count ?? 0 }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    NSTextField(labelWithString: tableView === lists ? archive.playlists[row].name : selected!.entries[row].title)
  }
  func tableViewSelectionDidChange(_ notification: Notification) { if notification.object as? NSTableView === lists { entries.reloadData() } }
  private func editName(_ initial: String = "", completion: @escaping (String) -> Void) {
    let alert = NSAlert(); alert.messageText = "Playlist name"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); field.stringValue = initial; alert.accessoryView = field
    alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
    guard let window else { return }
    alert.beginSheetModal(for: window) { response in
      let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if response == .alertFirstButtonReturn && !name.isEmpty { completion(name) }
    }
  }
  private func persist(_ changed: NASPlaylistArchive) {
    do {
      let latest = try NASPlaylistArchive.read(url)
      guard latest.playlists.map({ "\($0.id):\($0.modified.timeIntervalSince1970)" }) == archive.playlists.map({ "\($0.id):\($0.modified.timeIntervalSince1970)" }) else {
        archive = latest; lists.reloadData(); entries.reloadData()
        status.stringValue = "Playlists changed in another window. Reloaded; please repeat this action."
        return
      }
      try changed.write(url); archive = changed; lists.reloadData(); entries.reloadData(); status.stringValue = "Saved locally. Playback addresses are resolved on demand." }
    catch { status.stringValue = error.localizedDescription }
  }
  @objc private func saveCurrent() {
    player.getPlaylist()
    let snapshot = player.info.playlist.map { NASQueueEntry.decode($0.filename) ?? .local($0.filename, title: $0.filenameForDisplay) }
    editName { [self] name in var changed = archive; changed.playlists.append(NASSavedPlaylist(name: name, entries: snapshot)); persist(changed) }
  }
  @objc private func rename() {
    guard let selected else { return }
    editName(selected.name) { [self] name in
      var changed = archive
      guard let index = changed.playlists.firstIndex(where: { $0.id == selected.id }) else { return }
      changed.playlists[index].name = name; changed.playlists[index].modified = Date(); persist(changed)
    }
  }
  @objc private func copyList() {
    guard let selected else { return }
    editName(selected.name + " copy") { [self] name in var changed = archive; changed.playlists.append(NASSavedPlaylist(name: name, entries: selected.entries)); persist(changed) }
  }
  @objc private func merge() {
    let snapshot = lists.selectedRowIndexes.flatMap { archive.playlists[$0].entries }
    guard !snapshot.isEmpty else { return }
    editName { [self] name in var changed = archive; changed.playlists.append(NASSavedPlaylist(name: name, entries: snapshot)); persist(changed) }
  }
  @objc private func deleteList() {
    let ids = Set(lists.selectedRowIndexes.map { archive.playlists[$0].id })
    var changed = archive; changed.playlists.removeAll { ids.contains($0.id) }; persist(changed)
  }
  @objc private func appendSelection() {
    guard let selected else { return }
    let snapshot = entries.selectedRowIndexes.isEmpty ? selected.entries : entries.selectedRowIndexes.map { selected.entries[$0] }
    player.nas.append(snapshot)
  }
}
