import Cocoa

final class SettingsPageNAS: SettingsPage {
  override var identifier: String { "nas" }
  override var title: String { "NAS / Jellyfin" }
  override var image: NSImage { .sf("externaldrive.connected.to.line.below", withConfiguration: symbolConfiguration)! }
  override var showSubSections: Bool { false }

  private let store = NASStore(directory: Utility.appSupportDirUrl.appendingPathComponent("NAS", isDirectory: true))
  private let credentials = JellyfinCredentialStore()
  private var configuration = NASConfiguration()
  private var loadError: Error?
  private var task: Task<Void, Never>?
  private var operationID: UUID?
  private var controls: [NSControl] = []
  private let servers = NSPopUpButton()
  private let name = NSTextField()
  private let address = NSTextField()
  private let username = NSTextField()
  private let password = NSSecureTextField()
  private let mappings = NSPopUpButton()
  private let localRoot = NSTextField()
  private let remoteRoot = NSTextField()
  private let priority = NSTextField(string: "0")
  private let caseSensitive = NSButton(checkboxWithTitle: NSLocalizedString("Case-sensitive paths", comment: "NAS"), target: nil, action: nil)
  private let testPath = NSTextField()
  private let status = NSTextField(wrappingLabelWithString: "")
  private let mappingStatus = NSTextField(wrappingLabelWithString: "")
  private let progress = NSProgressIndicator()
  private var statusMessage = "" {
    didSet {
      status.stringValue = statusMessage
      mappingStatus.stringValue = statusMessage
    }
  }
  private var cancelButton: NSButton!

  override init() {
    super.init()
    do { configuration = try store.load() } catch { loadError = error }
  }

  private func text(_ value: String) -> String { NSLocalizedString(value, comment: "NAS") }
  private var selectedServer: NASServer? {
    configuration.servers.indices.contains(servers.indexOfSelectedItem) ? configuration.servers[servers.indexOfSelectedItem] : nil
  }
  private var serverMappings: [NASPathMapping] { configuration.mappings.filter { $0.server == selectedServer?.id } }

  override func content() -> [SettingsSection] {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    func label(_ value: String) { stack.addArrangedSubview(NSTextField(labelWithString: text(value))) }
    func field(_ caption: String, _ control: NSControl) {
      label(caption)
      stack.addArrangedSubview(control)
      control.translatesAutoresizingMaskIntoConstraints = false
      control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      controls.append(control)
    }
    func buttons(_ definitions: [(String, Selector)]) {
      let row = NSStackView()
      row.spacing = 8
      for (title, action) in definitions {
        let button = NSButton(title: text(title), target: self, action: action)
        row.addArrangedSubview(button)
        controls.append(button)
      }
      stack.addArrangedSubview(row)
    }
    let browse = NSButton(title: text("Browse NAS"), target: self, action: #selector(browseNAS))
    stack.addArrangedSubview(browse)
    let quality = NSPopUpButton()
    quality.addItems(withTitles: NASQuality.allCases.map { $0.label })
    quality.selectItem(at: NASQuality.allCases.firstIndex(of: NASQuality(rawValue: UserDefaults.standard.string(forKey: "nasQuality") ?? "auto") ?? .auto) ?? 0)
    quality.target = self; quality.action = #selector(qualityChanged(_:))
    field("Default playback quality", quality)
    let bitrate = NSPopUpButton()
    bitrate.addItems(withTitles: NASBitrate.allCases.map { $0.label })
    bitrate.selectItem(at: NASBitrate.allCases.firstIndex(of: .preferred) ?? 0)
    bitrate.target = self; bitrate.action = #selector(bitrateChanged(_:))
    field("Jellyfin 转码最高码率", bitrate)
    let resume = NSButton(checkboxWithTitle: text("Resume Jellyfin playback position"), target: self, action: #selector(resumeChanged(_:)))
    resume.state = (UserDefaults.standard.object(forKey: "nasResume") as? Bool ?? true) ? .on : .off
    stack.addArrangedSubview(resume)
    let skip = NSButton(checkboxWithTitle: text("Skip duplicate media"), target: self, action: #selector(skipChanged(_:)))
    skip.state = (UserDefaults.standard.object(forKey: "nasSkipDuplicates") as? Bool ?? true) ? .on : .off
    stack.addArrangedSubview(skip)
    field("Jellyfin servers", servers)
    servers.target = self; servers.action = #selector(serverChanged)
    buttons([("Add server", #selector(addServer)), ("Delete server", #selector(deleteServer))])
    field("Server name", name)
    field("Server address (including any /jellyfin base path)", address)
    field("Username", username)
    field("Password (saved only as a Keychain token)", password)
    buttons([("Save server", #selector(saveServer)), ("Sign in", #selector(signIn))])
    buttons([("Test connection", #selector(testConnection)), ("Refresh index", #selector(refreshIndex))])
    status.isSelectable = true
    stack.addArrangedSubview(status)
    status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    progress.style = .spinning
    progress.controlSize = .small
    progress.isDisplayedWhenStopped = false
    cancelButton = NSButton(title: text("Cancel operation"), target: self, action: #selector(cancelOperation))
    cancelButton.isEnabled = false
    stack.addArrangedSubview(NSStackView(views: [progress, cancelButton]))
    label("Path mappings — longest root wins, then highest priority")
    field("Saved mappings", mappings)
    mappings.target = self; mappings.action = #selector(mappingChanged)
    field("Local mount directory", localRoot)
    field("Jellyfin directory (absolute POSIX path)", remoteRoot)
    field("Priority", priority)
    stack.addArrangedSubview(caseSensitive); controls.append(caseSensitive)
    buttons([("New mapping", #selector(newMapping)), ("Save mapping", #selector(saveMapping)), ("Delete mapping", #selector(deleteMapping))])
    field("SMB file path to test", testPath)
    buttons([("Test path", #selector(testMapping))])
    label("Index refresh is a complete scan. It preserves the previous index if interrupted. Unmatched paths require a refresh before retrying.")
    mappingStatus.isSelectable = true
    stack.addArrangedSubview(mappingStatus)
    mappingStatus.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    reloadServers()
    statusMessage = text("Add or select a server, then sign in before testing the connection or refreshing the index.")
    if let error = loadError { show(error); controls.forEach { $0.isEnabled = false } }
    return sections { section { SettingsItem.Custom().view(stack) } }
  }

  @objc private func browseNAS() { PlayerCore.active.nas.showBrowser() }
  @objc private func bitrateChanged(_ sender: NSPopUpButton) { NASBitrate.preferred = NASBitrate.allCases[sender.indexOfSelectedItem] }
  @objc private func qualityChanged(_ sender: NSPopUpButton) { UserDefaults.standard.set(NASQuality.allCases[sender.indexOfSelectedItem].rawValue, forKey: "nasQuality") }
  @objc private func resumeChanged(_ sender: NSButton) { UserDefaults.standard.set(sender.state == .on, forKey: "nasResume") }
  @objc private func skipChanged(_ sender: NSButton) { UserDefaults.standard.set(sender.state == .on, forKey: "nasSkipDuplicates") }

  private func show(_ error: Error) {
    // Only our safe API errors or local filesystem errors reach this UI, never response bodies.
    statusMessage = error.localizedDescription
  }
  private func persist(_ updated: NASConfiguration) throws {
    try store.save(updated)
    configuration = updated
  }
  private func reloadServers(select id: UUID? = nil) {
    servers.removeAllItems()
    servers.addItems(withTitles: configuration.servers.map { $0.name })
    if let id, let index = configuration.servers.firstIndex(where: { $0.id == id }) { servers.selectItem(at: index) }
    serverChanged()
  }
  @objc private func serverChanged() {
    let server = selectedServer
    name.stringValue = server?.name ?? ""
    address.stringValue = server?.baseURL.absoluteString ?? ""
    username.stringValue = server?.username ?? ""
    password.stringValue = ""
    reloadMappings()
  }
  private func reloadMappings() {
    mappings.removeAllItems()
    mappings.addItems(withTitles: serverMappings.map { "\($0.localRoot) → \($0.remoteRoot)" })
    mappingChanged()
  }
  @objc private func mappingChanged() {
    guard serverMappings.indices.contains(mappings.indexOfSelectedItem) else { newMapping(); return }
    let rule = serverMappings[mappings.indexOfSelectedItem]
    localRoot.stringValue = rule.localRoot; remoteRoot.stringValue = rule.remoteRoot
    priority.stringValue = String(rule.priority); caseSensitive.state = rule.caseSensitive ? .on : .off
  }
  @objc private func newMapping() {
    mappings.select(nil)
    localRoot.stringValue = ""; remoteRoot.stringValue = ""; priority.stringValue = "0"; caseSensitive.state = .on
  }
  @objc private func addServer() {
    do {
      var updated = configuration
      let server = NASServer(name: text("New server"), baseURL: URL(string: "http://localhost:8096")!)
      updated.servers.append(server)
      try persist(updated); reloadServers(select: server.id)
    } catch { show(error) }
  }
  @objc private func deleteServer() {
    guard let server = selectedServer else { return }
    do {
      try credentials.remove(server)
      var updated = configuration
      updated.servers.removeAll { $0.id == server.id }
      updated.mappings.removeAll { $0.server == server.id }
      try persist(updated)
      try store.removeIndex(for: server.id)
      reloadServers()
    } catch { reloadServers(); show(error) }
  }
  @objc private func saveServer() {
    do { _ = try saveServerFields(); statusMessage = text("Server saved. Sign in after changing its address or username.") }
    catch { show(error) }
  }
  @discardableResult private func saveServerFields() throws -> NASServer {
    guard var server = selectedServer, let index = configuration.servers.firstIndex(where: { $0.id == server.id }) else { throw NASError.authentication }
    let url = try JellyfinClient.serverURL(address.stringValue)
    let user = username.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if server.baseURL != url || server.username != user {
      try credentials.remove(server)
      server.serverID = nil; server.userID = nil
    }
    server.name = name.stringValue.isEmpty ? url.host! : name.stringValue
    server.baseURL = url; server.username = user
    var updated = configuration; updated.servers[index] = server
    try persist(updated)
    servers.item(at: index)?.title = server.name
    return server
  }

  private func run(_ message: String, _ operation: @escaping @MainActor () async throws -> String) {
    guard task == nil else { return }
    controls.forEach { $0.isEnabled = false }; cancelButton.isEnabled = true
    statusMessage = text(message)
    progress.startAnimation(nil)
    operationID = UUID()
    task = Task { @MainActor in
      defer {
        progress.stopAnimation(nil)
        task = nil
        operationID = nil
        controls.forEach { $0.isEnabled = true }; cancelButton.isEnabled = false
      }
      do { statusMessage = try await operation() }
      catch is CancellationError { statusMessage = text("Operation cancelled. Previous index retained.") }
      catch { show(error) }
    }
  }
  @objc private func cancelOperation() { task?.cancel() }
  @objc private func signIn() {
    do {
      let server = try saveServerFields()
      let secret = password.stringValue; password.stringValue = ""
      let device = configuration.deviceID
      run("Signing in…") { [self] in
        let login = try await JellyfinClient(deviceID: device).login(baseURL: server.baseURL, username: server.username, password: secret)
        try Task.checkCancellation()
        var signedIn = server
        signedIn.serverID = login.ServerId; signedIn.userID = login.User.Id
        let credentialServer = signedIn
        try await Task.detached { try JellyfinCredentialStore().write(login.AccessToken, for: credentialServer) }.value
        var updated = configuration
        guard let index = updated.servers.firstIndex(where: { $0.id == server.id }) else { throw CancellationError() }
        updated.servers[index] = signedIn
        try persist(updated)
        if server.userID != nil && (server.userID != signedIn.userID || server.serverID != signedIn.serverID) { try credentials.remove(server) }
        return text("Signed in. Refresh the media index to enable path matching.")
      }
    } catch { show(error) }
  }
  @objc private func testConnection() {
    do {
      let server = try saveServerFields(), device = configuration.deviceID
      run("Testing connection…") { [self] in
        let token = try await Task.detached { try JellyfinCredentialStore().read(server) }.value
        try Task.checkCancellation()
        try await JellyfinClient(deviceID: device).test(server: server, token: token)
        return text("Connected. Server and account verified.")
      }
    } catch { show(error) }
  }
  @objc private func refreshIndex() {
    do {
      let server = try saveServerFields(), device = configuration.deviceID
      run("Refreshing media index…") { [self] in
        let token = try await Task.detached { try JellyfinCredentialStore().read(server) }.value
        try Task.checkCancellation()
        let ticket = operationID
        let index = try await JellyfinClient(deviceID: device).index(server: server, token: token) { [weak self] count, total in
          Task { @MainActor in
            guard let self, self.operationID == ticket else { return }
            self.statusMessage = String(format: NSLocalizedString("Indexed %d of %d videos…", comment: "NAS"), count, total)
          }
        }
        try Task.checkCancellation()
        let store = self.store
        try await Task.detached { try store.save(index, for: server.id) }.value
        return String(format: text("Index saved: %d media paths; %d videos without paths."), index.media.count, index.missingPaths)
      }
    } catch { show(error) }
  }
  @objc private func saveMapping() {
    guard let server = selectedServer else { return }
    do {
      _ = try NASPathMapper.components(localRoot.stringValue)
      _ = try NASPathMapper.components(remoteRoot.stringValue)
      guard let rank = Int(priority.stringValue) else { throw NASError.invalidPath }
      let current = serverMappings.indices.contains(mappings.indexOfSelectedItem) ? serverMappings[mappings.indexOfSelectedItem].id : UUID()
      let rule = NASPathMapping(id: current, server: server.id, localRoot: localRoot.stringValue,
                                remoteRoot: remoteRoot.stringValue, caseSensitive: caseSensitive.state == .on, priority: rank)
      var updated = configuration
      updated.mappings.removeAll { $0.id == current }; updated.mappings.append(rule)
      try persist(updated); reloadMappings()
      mappings.selectItem(at: serverMappings.count - 1); mappingChanged()
      statusMessage = text("Mapping saved.")
    } catch { show(error) }
  }
  @objc private func deleteMapping() {
    guard serverMappings.indices.contains(mappings.indexOfSelectedItem) else { return }
    let id = serverMappings[mappings.indexOfSelectedItem].id
    do {
      var updated = configuration; updated.mappings.removeAll { $0.id == id }
      try persist(updated); reloadMappings()
    } catch { show(error) }
  }
  @objc private func testMapping() {
    let path = testPath.stringValue, rules = configuration.mappings, servers = configuration.servers, store = self.store
    run("Testing path mapping…") { [self] in
      let result = try await Task.detached { () throws -> (String, NASMedia) in
        let (rule, remote) = try NASPathMapper.map(path, rules: rules)
        guard let server = servers.first(where: { $0.id == rule.server }) else { throw NASError.noMapping }
        let index = try store.index(for: server)
        return (remote, try NASPathMapper.match(remote, in: index, caseSensitive: rule.caseSensitive))
      }.value
      try Task.checkCancellation()
      return text("Matched:") + " \(result.1.title)\n\(result.0)\nItemId: \(result.1.itemID)"
    }
  }
}
