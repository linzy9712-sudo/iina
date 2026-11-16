import Foundation

// Test double for the importer boundary. No global/new-player routing exists here.
final class PlayerCore {
  struct Item { let filename: String; var isNetworkResource = false }
  enum State { case playing, idle, stopping; var active: Bool { self == .playing } }
  final class Info { var state = State.playing; var playlist: [Item] = [] }
  enum OSD { case addToPlaylist(Int), custom(String) }
  let info = Info()
  let nas = NASPlayerCoordinator()
  var opens = 0
  var completions = 0
  var position = 42.0
  var paused = true
  func getPlaylist() {}
  func addToPlaylist(paths: [String]) { info.playlist += paths.map { Item(filename: $0) } }
  func sendOSD(_ message: OSD) { if case .addToPlaylist = message { completions += 1 } }
  func openURLs(_ urls: [URL], shouldAutoLoad: Bool) {
    precondition(!shouldAutoLoad)
    opens += 1; info.state = .playing
    info.playlist = urls.map { Item(filename: $0.path) }
  }
}
enum Utility {
  enum Kind { case video }
  static let supportedFileExt: [Kind: [String]] = [.video: ["mkv", "mp4"]]
}

@main struct FolderDropRegression {
  static func main() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let first = base.appendingPathComponent("first"), second = base.appendingPathComponent("second")
    for directory in [first, second, first.appendingPathComponent("nested")] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    for name in ["first/10.mkv", "first/2.mkv", "first/.hidden.mkv", "first/readme.txt", "first/nested/3.mp4", "second/1.mkv"] {
      try Data([1]).write(to: base.appendingPathComponent(name))
    }
    let paths = FolderVideoScanner.scan([first, second, first], videoExtensions: ["mkv", "mp4"])
    precondition(paths.map { URL(fileURLWithPath: $0).lastPathComponent } == ["2.mkv", "3.mp4", "10.mkv", "1.mkv"])
    let player = PlayerCore()
    player.info.playlist = [.init(filename: "/playing.mkv")]
    let importer = FolderPlaylistImporter(player: player)
    importer.enqueue([first, second])
    wait { player.completions == 1 }
    precondition(player.opens == 0 && player.info.playlist.count == 5)
    precondition(player.info.playlist.first!.filename == "/playing.mkv" && player.position == 42 && player.paused)
    importer.enqueue([first, second])
    wait { player.completions == 2 }
    precondition(player.info.playlist.count == 5)
    let idle = PlayerCore(); idle.info.state = .idle
    let idleImporter = FolderPlaylistImporter(player: idle)
    idleImporter.enqueue([first, second])
    wait { idle.opens == 1 }
    precondition(idle.info.playlist.count == 4 && idle.opens == 1)
    let cancelled = PlayerCore()
    let cancelledImporter = FolderPlaylistImporter(player: cancelled)
    cancelledImporter.enqueue([first, second]); cancelledImporter.cancel()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    precondition(cancelled.info.playlist.isEmpty && cancelled.opens == 0)
    print("PASS: multi-folder order, recursion, filtering, deduplication, uninterrupted append, single-player idle open and cancelled import")
  }
  static func wait(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(predicate(), "Importer timed out")
  }
}

final class NASPlayerCoordinator {
  static let store = NASStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("iina-empty-config-" + UUID().uuidString))
  func recordImport(_ errors: [String]) { precondition(errors.isEmpty) }
}

enum NASImportService {
  static func resolve(_ paths: [String], progress: @escaping (Int, Int) -> Void) async throws -> (entries: [NASQueueEntry], errors: [String]) {
    try Task.checkCancellation()
    return (paths.map { .local($0) }, [])
  }
}
