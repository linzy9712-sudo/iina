import Foundation

/// The URI is a stable, credential-free queue identity, never a playback URL.
struct NASQueueEntry: Codable, Equatable, Identifiable {
  var id = UUID()
  var title: String
  var location: String?
  var server: UUID?
  var serverID: String?
  var itemID: String?
  var sourceID: String?

  var identity: String {
    if let serverID, let itemID { return "jellyfin:\(serverID):\(itemID)" }
    return location ?? ""
  }
  var mpvPath: String {
    guard itemID != nil else { return location ?? "" }
    let data = try! JSONEncoder().encode(self)
    return "iina-jellyfin://media/" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  static func decode(_ path: String) -> NASQueueEntry? {
    let prefix = "iina-jellyfin://media/"
    guard path.hasPrefix(prefix), path.count < 32768 else { return nil }
    var encoded = String(path.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded), let entry = try? JSONDecoder().decode(Self.self, from: data),
          entry.server != nil, entry.serverID != nil, let item = entry.itemID, !item.isEmpty,
          entry.location == nil else { return nil }
    return entry
  }
  static func local(_ path: String, title: String? = nil) -> Self {
    Self(title: title ?? URL(fileURLWithPath: path).lastPathComponent, location: path)
  }
  static func remote(_ media: NASMedia, server: NASServer) -> Self {
    Self(title: media.title, server: server.id, serverID: server.serverID, itemID: media.itemID, sourceID: media.sourceID)
  }
}

struct NASSavedPlaylist: Codable, Identifiable {
  var id = UUID()
  var name: String
  var modified = Date()
  var entries: [NASQueueEntry]
}
struct NASPlaylistArchive: Codable {
  var version = 1
  var playlists: [NASSavedPlaylist] = []
  static func read(_ url: URL) throws -> Self {
    guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
    let archive = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    guard archive.version == 1 else { throw NASError.incompatibleStore }
    return archive
  }
  func write(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(self).write(to: url, options: .atomic)
  }
}

enum NASQuality: String, CaseIterable {
  case auto, original, transcode, hd1080, hd720
  var label: String {
    switch self {
    case .auto: return "Auto"
    case .original: return "Original"
    case .transcode: return "NAS transcoding"
    case .hd1080: return "1080p"
    case .hd720: return "720p"
    }
  }
  var forcesTranscode: Bool { self != .auto && self != .original }
  var bitrate: Int { self == .original ? Int(Int32.max) : self == .hd720 ? 4_000_000 : self == .hd1080 ? 10_000_000 : 40_000_000 }
}

/// Reused by Finder import and the browser. Missing or ambiguous NAS paths never fall back to SMB playback.
enum NASImportResolver {
  static func resolve(_ paths: [String], configuration: NASConfiguration, store: NASStore) -> (entries: [NASQueueEntry], errors: [String]) {
    var entries: [NASQueueEntry] = [], errors: [String] = []
    var indexes: [UUID: NASPathLookup] = [:]
    for path in paths {
      do {
        let mapped: (NASPathMapping, String)
        do { mapped = try NASPathMapper.map(path, rules: configuration.mappings) }
        catch NASError.noMapping { entries.append(.local(path)); continue }
        guard let server = configuration.servers.first(where: { $0.id == mapped.0.server }) else { throw NASError.noMapping }
        if indexes[server.id] == nil { indexes[server.id] = NASPathLookup(try store.index(for: server)) }
        let media = try indexes[server.id]!.match(mapped.1, caseSensitive: mapped.0.caseSensitive)
        entries.append(.remote(media, server: server))
      } catch { errors.append("\(URL(fileURLWithPath: path).lastPathComponent): \(error.localizedDescription)") }
    }
    return (entries, errors)
  }
}

/// Build once per import instead of scanning the entire index for every dropped file.
struct NASPathLookup {
  private var exact: [String: [NASMedia]] = [:]
  private var folded: [String: [NASMedia]] = [:]
  init(_ index: NASIndex) {
    for media in index.media {
      if let key = try? NASPathMapper.key(media.path, caseSensitive: true) { exact[key, default: []].append(media) }
      if let key = try? NASPathMapper.key(media.path, caseSensitive: false) { folded[key, default: []].append(media) }
    }
  }
  func match(_ path: String, caseSensitive: Bool) throws -> NASMedia {
    let key = try NASPathMapper.key(path, caseSensitive: caseSensitive)
    let matches = (caseSensitive ? exact : folded)[key] ?? []
    guard let first = matches.first else { throw NASError.missingMedia }
    guard matches.allSatisfy({ $0.itemID == first.itemID && $0.sourceID == first.sourceID && $0.path == first.path }) else { throw NASError.ambiguousMedia }
    return first
  }
}
