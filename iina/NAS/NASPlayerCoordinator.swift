import Cocoa

/// All mutable state is owned by the main thread. Network operations suspend without blocking mpv's event queue.
final class NASPlayerCoordinator {
  unowned let player: PlayerCore
  static var store: NASStore {
#if DEBUG
    if let path = ProcessInfo.processInfo.environment["IINA_NAS_TEST_DATA"] {
      return NASStore(directory: URL(fileURLWithPath: path, isDirectory: true))
    }
#endif
    return NASStore(directory: Utility.appSupportDirUrl.appendingPathComponent("NAS", isDirectory: true))
  }
  private var generation = 0
  private var resolving: Task<Void, Never>?
  private var continuation: (() -> Void)?
  private var timer: Timer?
  private var session: Session?
  private struct TrackChoice { var audio: Int?; var subtitle: Int?; var ticks: Int64? }
  private var choices: [String: TrackChoice] = [:]
  private var subtitleTask: Task<Void, Never>?
  private var subtitleFile: URL?
  private(set) var diagnostic = "" {
    didSet {
      if player.info.state.active { player.mpv.setNode("user-data/iina-nas-status", diagnostic) }
    }
  }
  private(set) var importErrors: [String] = []
  func recordImport(_ errors: [String]) {
    importErrors = errors
    if !errors.isEmpty { player.sendOSD(.custom("\(errors.count) NAS files could not be imported. See NAS browser → Import results.")) }
  }
  private var browser: NASBrowserWindowController?
  private var library: NASPlaylistWindowController?

  private final class Session {
    let entry: NASQueueEntry
    let server: NASServer
    let token: String
    let plan: JellyfinPlaybackPlan
    let client: JellyfinClient
    var started = false
    var lastError: String?
    var ticks: Int64 = 0
    var reports: Task<Void, Never>?
    init(entry: NASQueueEntry, server: NASServer, token: String, plan: JellyfinPlaybackPlan, client: JellyfinClient) {
      self.entry = entry; self.server = server; self.token = token; self.plan = plan; self.client = client
    }
    func send(_ event: String, paused: Bool) {
      let previous = reports, position = ticks
      reports = Task { @MainActor [self] in
        await previous?.value
        do { try await client.report(server: server, token: token, entry: entry, plan: plan, event: event, ticks: position, paused: paused) }
        catch { lastError = error.localizedDescription }
        if event == "/Stopped", plan.transcode { try? await client.stopTranscode(server: server, token: token, sessionID: plan.sessionID) }
      }
    }
  }

  init(player: PlayerCore) { self.player = player }

  func install() {
    #if DEBUG
    player.mpv.setNode("user-data/iina-nas-installed", true)
    #endif
    player.mpv.addHook(.onLoad, priority: 20, hook: MPVHookValue(withBlock: { [weak self] next in
      guard let self else { next(); return }
      let path = self.player.mpv.getString(MPVProperty.path) ?? ""
      DispatchQueue.main.async { [weak self] in
        guard let self else { next(); return }
        self.load(path, next: next)
      }
    }))
  }

  func invalidate() {
    generation += 1
    resolving?.cancel(); resolving = nil
    if let next = continuation {
      continuation = nil
      player.mpv.setNode(MPVProperty.streamOpenFilename, "memory://")
      next()
    }
  }

  private func load(_ path: String, next: @escaping () -> Void) {
    invalidate()
    finish()
    #if DEBUG
    player.mpv.setNode("user-data/iina-nas-hook", "scheme=" + (URL(string: path)?.scheme ?? "none"))
    player.mpv.setNode("user-data/iina-nas-entry-valid", NASQueueEntry.decode(path) != nil)
    #endif
    guard let entry = NASQueueEntry.decode(path) else { next(); return }
    continuation = next
    let ticket = generation
    diagnostic = NSLocalizedString("Resolving Jellyfin media…", comment: "NAS")
    resolving = Task { @MainActor [self] in
      var negotiated: Session?
      do {
        let configuration = try await Task.detached { try Self.store.load() }.value
        guard let server = configuration.servers.first(where: { $0.id == entry.server && $0.serverID == entry.serverID }) else { throw NASError.authentication }
        let token = try await Task.detached { try JellyfinCredentialStore().read(server) }.value
        try Task.checkCancellation()
        let client = JellyfinClient(deviceID: configuration.deviceID)
        let quality = NASQuality(rawValue: UserDefaults.standard.string(forKey: "nasQuality") ?? "auto") ?? .auto
        let choice = choices[entry.identity]
        choices[entry.identity]?.ticks = nil
        let plan = try await client.playback(server: server, entry: entry, token: token, quality: quality,
                                            resume: UserDefaults.standard.object(forKey: "nasResume") as? Bool ?? true,
                                            audioIndex: choice?.audio, subtitleIndex: choice?.subtitle, startTicks: choice?.ticks)
        let active = Session(entry: entry, server: server, token: token, plan: plan, client: client)
        negotiated = active
        try Task.checkCancellation()
        guard generation == ticket, player.info.state.active else { throw CancellationError() }
        session = active
        // Native mpv file logs cannot be redacted. Disable them before any secret is passed.
        player.mpv.protectJellyfinLogs()
        player.mpv.setNode("file-local-options/http-header-fields", ["X-Emby-Token: \(token)"])
        player.mpv.setNode("file-local-options/ytdl", false)
        player.mpv.setNode("file-local-options/force-media-title", entry.title)
        player.mpv.setNode("file-local-options/start", String(Double(plan.resumeTicks) / 10_000_000))
        player.mpv.setNode(MPVProperty.streamOpenFilename, plan.url.absoluteString)
        diagnostic = "\(entry.title) — \(plan.transcode ? "HLS / Transcode" : "Direct Play")"
        complete(ticket)
      } catch {
        if let negotiated, negotiated.plan.transcode {
          try? await negotiated.client.stopTranscode(server: negotiated.server, token: negotiated.token, sessionID: negotiated.plan.sessionID)
        }
        guard generation == ticket else { return }
        diagnostic = error is CancellationError ? NSLocalizedString("Playback cancelled", comment: "NAS") : error.localizedDescription
        player.sendOSD(.custom(diagnostic))
        player.mpv.setNode(MPVProperty.streamOpenFilename, "memory://")
        complete(ticket)
      }
    }
  }

  private func complete(_ ticket: Int) {
    guard generation == ticket, let next = continuation else { return }
    continuation = nil; resolving = nil; next()
  }
  func loaded() {
    guard let session, !session.started else { return }
    session.started = true
    sample()
    session.send("", paused: player.info.state == .paused)
    configureTracks(session)
    timer?.invalidate()
    let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.progress() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }
  private func sample() {
    guard let session else { return }
    let seconds = player.info.videoPosition?.second ?? 0
    if seconds.isFinite { session.ticks = Int64(max(0, min(seconds, Double(Int64.max) / 10_000_000 - 1)) * 10_000_000) }
  }
  func progress() {
    guard let session, session.started else { return }
    sample(); session.send("/Progress", paused: player.info.state == .paused)
  }
  func finish() {
    subtitleTask?.cancel(); subtitleTask = nil
    if let subtitleFile { try? FileManager.default.removeItem(at: subtitleFile) }
    subtitleFile = nil
    timer?.invalidate(); timer = nil
    guard let current = session else { return }
    sample(); session = nil
    current.send("/Stopped", paused: true)
  }

  private func configureTracks(_ active: Session) {
    if !active.plan.transcode, let tracks = player.mpv.getNode(MPVProperty.trackList) as? [[String: Any]] {
      for (kind, index) in [("audio", active.plan.audioIndex), ("sub", active.plan.subtitleIndex)] {
        if index == -1 && kind == "sub" { player.setTrack(0, forType: .sub) }
        if let index, let track = tracks.first(where: { $0["type"] as? String == kind && ($0["ff-index"] as? NSNumber)?.intValue == index }),
           let id = track["id"] as? NSNumber { player.setTrack(id.intValue, forType: kind == "audio" ? .audio : .sub) }
      }
    }
    guard let index = active.plan.subtitleIndex,
          let stream = active.plan.streams.first(where: { $0.Index == index && $0.kind == "Subtitle" && $0.DeliveryUrl != nil }) else { return }
    subtitleTask = Task { @MainActor [weak self] in
      do {
        let data = try await active.client.subtitle(server: active.server, token: active.token, stream: stream)
        try Task.checkCancellation()
        guard let self, self.session === active else { return }
        let ext = ["ass", "ssa", "vtt"].contains(stream.Codec ?? "") ? stream.Codec! : "srt"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("iina-sub-" + UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: file, options: .atomic)
        self.subtitleFile = file
        self.player.loadExternalSubFile(file)
      } catch { if let self, self.session === active { self.diagnostic = "Subtitle: " + error.localizedDescription } }
    }
  }

  func showTracks() {
    guard let active = session else { player.sendOSD(.custom("Play a Jellyfin video first.")); return }
    let audio = NSPopUpButton(), subtitles = NSPopUpButton()
    audio.addItem(withTitle: "Default audio"); audio.lastItem?.tag = -2
    subtitles.addItem(withTitle: "Subtitles off"); subtitles.lastItem?.tag = -1
    for stream in active.plan.streams {
      let popup = stream.kind == "Audio" ? audio : stream.kind == "Subtitle" ? subtitles : nil
      popup?.addItem(withTitle: stream.DisplayTitle ?? "\(stream.kind) \(stream.Index)"); popup?.lastItem?.tag = stream.Index
    }
    audio.selectItem(withTag: active.plan.audioIndex ?? -2); subtitles.selectItem(withTag: active.plan.subtitleIndex ?? -1)
    let alert = NSAlert(); alert.messageText = "Jellyfin audio and subtitles"
    alert.informativeText = "Changing tracks reloads this video at its current position."
    let stack = NSStackView(views: [audio, subtitles]); stack.orientation = .vertical; stack.frame = NSRect(x: 0, y: 0, width: 340, height: 70)
    alert.accessoryView = stack; alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
    guard let window = player.currentWindow else { return }
    alert.beginSheetModal(for: window) { [weak self] result in
      guard let self, result == .alertFirstButtonReturn, self.session === active else { return }
      self.sample()
      self.choices[active.entry.identity] = TrackChoice(audio: audio.selectedTag() == -2 ? nil : audio.selectedTag(), subtitle: subtitles.selectedTag(), ticks: active.ticks)
      self.player.playFileInPlaylist(self.player.mpv.getInt(MPVProperty.playlistPos))
    }
  }

  func append(_ entries: [NASQueueEntry], play: Bool = false) {
    guard !entries.isEmpty else { return }
    player.getPlaylist()
    let skip = UserDefaults.standard.object(forKey: "nasSkipDuplicates") as? Bool ?? true
    if play, let first = entries.first, let index = player.info.playlist.firstIndex(where: { (NASQueueEntry.decode($0.filename)?.identity ?? $0.filename) == first.identity }) {
      player.playFileInPlaylist(index); return
    }
    var seen = Set(player.info.playlist.map { NASQueueEntry.decode($0.filename)?.identity ?? $0.filename })
    let additions = entries.filter { !skip || seen.insert($0.identity).inserted }.map { entry -> NASQueueEntry in
      var copy = entry; copy.id = UUID(); return copy
    }
    guard !additions.isEmpty else { player.sendOSD(.addToPlaylist(0)); return }
    if player.info.state == .idle {
      // Use this player directly, never the global new-window routing.
      player.openURLs(additions.compactMap { $0.location?.hasPrefix("/") == true ? URL(fileURLWithPath: $0.location!) : URL(string: $0.mpvPath) }, shouldAutoLoad: false)
    } else if player.info.state.active {
      let index = player.info.playlist.count
      player.addToPlaylist(paths: additions.map(\.mpvPath))
      if play { player.playFileInPlaylist(index) }
      else { player.sendOSD(.addToPlaylist(additions.count)) }
    }
  }

  private func placeBesideVideo(_ window: NSWindow) {
    guard let video = player.currentWindow, let screen = video.screen else { return }
    let bounds = screen.visibleFrame, frame = video.frame, gap: CGFloat = 12
    let size = window.frame.size
    if bounds.maxX - frame.maxX >= size.width + gap {
      window.setFrameOrigin(NSPoint(x: frame.maxX + gap, y: max(bounds.minY, min(frame.maxY - size.height, bounds.maxY - size.height))))
    } else if frame.minX - bounds.minX >= size.width + gap {
      window.setFrameOrigin(NSPoint(x: frame.minX - gap - size.width, y: max(bounds.minY, min(frame.maxY - size.height, bounds.maxY - size.height))))
    } else if let other = NSScreen.screens.first(where: { $0 != screen && $0.visibleFrame.width >= size.width }) {
      window.setFrameOrigin(NSPoint(x: other.visibleFrame.minX + 12, y: other.visibleFrame.maxY - size.height - 12))
    }
  }

  func showBrowser() {
    if browser == nil { browser = NASBrowserWindowController(player: player) }
    browser?.showWindow(nil)
    if let window = browser?.window { placeBesideVideo(window); window.makeKeyAndOrderFront(nil) }
  }
  func showLibrary() {
    if library == nil { library = NASPlaylistWindowController(player: player) }
    library?.showWindow(nil)
    if let window = library?.window { placeBesideVideo(window); window.makeKeyAndOrderFront(nil) }
  }
}
