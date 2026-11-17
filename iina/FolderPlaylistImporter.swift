import Foundation

/// Filesystem work only. Folder boundaries retain Finder's order; files within each folder use natural order.
enum FolderVideoScanner {
  static func normalizedPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  static func scan(_ inputs: [URL], videoExtensions: Set<String>, cancelled: @escaping () -> Bool = { false },
                   onError: @escaping (String) -> Void = { _ in }, progress: (Int) -> Void = { _ in }) -> [String] {
    let manager = FileManager.default
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey, .fileSizeKey, .isSymbolicLinkKey]
    var seen = Set<String>()
    var result: [String] = []
    func validVideo(_ url: URL) -> Bool {
      guard videoExtensions.contains(url.pathExtension.lowercased()),
            let values = try? url.resourceValues(forKeys: keys),
            values.isRegularFile == true, values.isHidden != true, values.isSymbolicLink != true,
            (values.fileSize ?? 0) > 0, manager.isReadableFile(atPath: url.path) else { return false }
      return true
    }
    for input in inputs {
      if cancelled() { return [] }
      guard let values = try? input.resourceValues(forKeys: keys), values.isHidden != true, values.isSymbolicLink != true else {
        onError("Cannot read or follow: \(input.path)"); continue
      }
      var files: [URL] = []
      if values.isDirectory == true {
        if let enumerator = manager.enumerator(at: input, includingPropertiesForKeys: Array(keys),
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                               errorHandler: { url, _ in onError("Cannot read: \(url.path)"); return !cancelled() }) {
          for case let file as URL in enumerator {
            if cancelled() { return [] }
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
            if validVideo(file) { files.append(file); if files.count % 256 == 0 { progress(result.count + files.count) } }
          }
        }
        files.sort {
          let comparison = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
          return comparison == .orderedSame ? $0.path < $1.path : comparison == .orderedAscending
        }
      } else if validVideo(input) {
        files = [input]
      }
      for file in files {
        let path = normalizedPath(file)
        if seen.insert(path).inserted { result.append(path) }
      }
    }
    return result
  }
}

/// Main-thread coordinator. Consecutive drops are completed in order, with small append batches.
final class FolderPlaylistImporter {
  private unowned let player: PlayerCore
  private let queue = DispatchQueue(label: "IINA.FolderVideoScanner", qos: .utility)
  private var pending: [[URL]] = []
  private var running = false
  private var generation = 0
  private var cancellation = FolderScanCancellation()
  private var resolution: Task<Void, Never>?

  init(player: PlayerCore) { self.player = player }

  func cancel() {
    cancellation.cancel(); resolution?.cancel(); resolution = nil
    generation += 1; pending.removeAll(); running = false
  }
  func enqueue(_ urls: [URL]) { pending.append(urls); startNext() }

  private func startNext() {
    guard !running, !pending.isEmpty else { return }
    guard player.info.state.active || player.info.state == .idle else { cancel(); return }
    running = true
    cancellation = FolderScanCancellation()
    let cancellation = self.cancellation, inputs = pending.removeFirst(), ticket = generation
    let beganIdle = player.info.state == .idle
    let extensions = Set(Utility.supportedFileExt[.video]!)
    queue.async { [weak self] in
      var scanErrors: [String] = []
      let paths = FolderVideoScanner.scan(inputs, videoExtensions: extensions, cancelled: { cancellation.isCancelled },
        onError: { scanErrors.append($0) }, progress: { count in
          DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == ticket else { return }
            self.player.sendOSD(.custom("Scanning: \(count) videos…"))
          }
        })
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == ticket else { return }
        self.resolution = Task { @MainActor [weak self] in
          guard let self else { return }
          do {
            let result = try await NASImportService.resolve(paths) { [weak self] count, total in
              DispatchQueue.main.async {
                guard let self, self.generation == ticket else { return }
                self.player.sendOSD(.custom("Indexing Jellyfin: \(count)/\(total)"))
              }
            }
            try Task.checkCancellation()
            guard self.generation == ticket else { return }
            self.player.nas.recordImport(scanErrors + result.errors)
            let media = result.entries.map(\.mpvPath)
            if self.player.info.state == .idle {
              guard beganIdle else { self.cancel(); return }
              if let first = media.first {
                let url = NASQueueEntry.decode(first) != nil ? URL(string: first)! : URL(fileURLWithPath: first)
                self.player.openURLs([url], shouldAutoLoad: false)
                self.append(Array(media.dropFirst()), offset: 0, added: 1, ticket: ticket)
              } else { self.finished() }
            } else { self.append(media, offset: 0, added: 0, ticket: ticket) }
          } catch {
            guard self.generation == ticket else { return }
            if !(error is CancellationError) { self.player.nas.recordImport([error.localizedDescription]) }
            self.finished()
          }
        }
      }
    }
  }
  private func finished() { resolution = nil; running = false; startNext() }
  private func append(_ paths: [String], offset: Int, added: Int, ticket: Int) {
    guard generation == ticket else { return }
    guard player.info.state.active else { cancel(); return }
    let end = min(offset + 32, paths.count)
    player.getPlaylist()
    var existing = Set(player.info.playlist.map { NASQueueEntry.decode($0.filename)?.identity ?? $0.filename })
    let skip = UserDefaults.standard.object(forKey: "nasSkipDuplicates") as? Bool ?? true
    let batch = paths[offset..<end].filter { !skip || existing.insert(NASQueueEntry.decode($0)?.identity ?? $0).inserted }
    if !batch.isEmpty { player.addToPlaylist(paths: batch) }
    let count = added + batch.count
    if end < paths.count {
      DispatchQueue.main.async { [weak self] in self?.append(paths, offset: end, added: count, ticket: ticket) }
    } else {
      player.sendOSD(.addToPlaylist(count)); finished()
    }
  }
}

private final class FolderScanCancellation {
  private let lock = NSLock()
  private var cancelled = false
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
