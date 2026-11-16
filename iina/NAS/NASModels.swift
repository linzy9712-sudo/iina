import Foundation

struct NASServer: Codable, Identifiable, Equatable {
  var id = UUID()
  var name: String
  var baseURL: URL
  var serverID: String?
  var userID: String?
  var username: String = ""
}

struct NASPathMapping: Codable, Identifiable, Equatable {
  var id = UUID()
  var server: UUID
  var localRoot: String
  var remoteRoot: String
  var caseSensitive = true
  var priority = 0
}

struct NASConfiguration: Codable {
  var version = 1
  var deviceID = UUID().uuidString
  var servers: [NASServer] = []
  var mappings: [NASPathMapping] = []
}

struct NASMedia: Codable, Equatable {
  let itemID: String
  let sourceID: String?
  let path: String
  let title: String
  let parentID: String?
  let durationTicks: Int64?
}

struct NASIndex: Codable {
  var version = 1
  let serverID: String
  let userID: String
  let baseURL: URL
  let refreshedAt: Date
  let missingPaths: Int
  let media: [NASMedia]
}

enum NASError: Error, LocalizedError {
  case invalidURL, invalidPath, noMapping, ambiguousMapping, missingMedia, ambiguousMedia
  case authentication, http(Int), transport, invalidResponse, missingPaths, noIndex, incompatibleStore, playbackUnavailable
  case keychain(Int32)
  case transportCode(Int)

  var errorDescription: String? {
    let message: String
    switch self {
    case .invalidURL: message = "Enter an HTTP or HTTPS server address without credentials, query or fragment."
    case .invalidPath: message = "Use absolute paths without parent-directory components."
    case .noMapping: message = "No path mapping matches this file."
    case .ambiguousMapping: message = "Multiple mappings have equal priority. Edit their priority or roots."
    case .missingMedia: message = "No indexed media matches this path. Refresh the index and check the mapping."
    case .ambiguousMedia: message = "Multiple media items match this path. No item was selected."
    case .authentication: message = "Authentication expired or access denied. Sign in again."
    case .http(let status): return String(format: NSLocalizedString("Jellyfin returned HTTP %d.", comment: "NAS error"), status)
    case .transportCode(let code):
      switch code {
      case -1022: message = "macOS blocked this HTTP connection (ATS -1022). Fully quit IINA and reopen the updated app."
      case -1001: message = "Jellyfin connection timed out (-1001). Check the server, port and VPN connection."
      case -1003: message = "Cannot resolve the Jellyfin hostname (-1003). Check the address and DNS."
      case -1004: message = "Cannot connect to the Jellyfin port (-1004). Check the port, server and firewall."
      case -1009: message = "Network access is unavailable (-1009). Check the network, VPN and macOS Local Network permission for IINA."
      case -1206 ... -1200: message = "Jellyfin HTTPS certificate or TLS verification failed. Check the certificate and server HTTPS configuration."
      default: return String(format: NSLocalizedString("Jellyfin network request failed (%d). Check the network and server address.", comment: "NAS error"), code)
      }
    case .transport: message = "Cannot reach Jellyfin. Check the address, network and certificate."
    case .playbackUnavailable: message = "Jellyfin could not provide the selected media source or quality. Try Auto, check server transcoding, or refresh the index."
    case .invalidResponse: message = "Jellyfin returned an invalid or incomplete response."
    case .missingPaths: message = "Jellyfin returned videos without readable paths. Check account permissions and server support."
    case .noIndex: message = "No index exists for this server address and account. Refresh the index."
    case .incompatibleStore: message = "This NAS data format is unsupported. It has not been overwritten."
    case .keychain(let status): return String(format: NSLocalizedString("Keychain operation failed (%d).", comment: "NAS error"), status)
    }
    return NSLocalizedString(message, comment: "NAS error")
  }
}

/// Pure lexical mapping: never performs SMB I/O on the UI thread.
enum NASPathMapper {
  static func components(_ path: String) throws -> [String] {
    guard path.hasPrefix("/"), !path.contains("\0") else { throw NASError.invalidPath }
    let parts = path.split(separator: "/").map(String.init)
    guard !parts.contains("..") else { throw NASError.invalidPath }
    return parts.filter { $0 != "." }
  }

  static func key(_ path: String, caseSensitive: Bool) throws -> String {
    let value = try components(path).map { $0.precomposedStringWithCanonicalMapping }.joined(separator: "/")
    return caseSensitive ? value : value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
  }

  static func map(_ path: String, rules: [NASPathMapping]) throws -> (NASPathMapping, String) {
    let parts = try components(path)
    let candidates = try rules.compactMap { rule -> (NASPathMapping, [String])? in
      let root = try components(rule.localRoot)
      _ = try components(rule.remoteRoot)
      guard parts.count > root.count else { return nil }
      let prefix = "/" + parts.prefix(root.count).joined(separator: "/")
      guard try key(prefix, caseSensitive: rule.caseSensitive) == key(rule.localRoot, caseSensitive: rule.caseSensitive) else { return nil }
      return (rule, root)
    }.sorted { a, b in
      a.1.count == b.1.count ? a.0.priority > b.0.priority : a.1.count > b.1.count
    }
    guard let best = candidates.first else { throw NASError.noMapping }
    if candidates.dropFirst().contains(where: { $0.1.count == best.1.count && $0.0.priority == best.0.priority }) {
      throw NASError.ambiguousMapping
    }
    let remote = try components(best.0.remoteRoot) + Array(parts.dropFirst(best.1.count))
    return (best.0, "/" + remote.joined(separator: "/"))
  }

  static func match(_ path: String, in index: NASIndex, caseSensitive: Bool) throws -> NASMedia {
    let target = try key(path, caseSensitive: caseSensitive)
    let matches = try index.media.filter { try key($0.path, caseSensitive: caseSensitive) == target }
    guard let first = matches.first else { throw NASError.missingMedia }
    guard matches.allSatisfy({ $0.itemID == first.itemID && $0.sourceID == first.sourceID && $0.path == first.path }) else {
      throw NASError.ambiguousMedia
    }
    return first
  }
}

/// Only non-secret configuration and media metadata are accepted by this store.
struct NASStore {
  let directory: URL
  private var configurationURL: URL { directory.appendingPathComponent("configuration.json") }

  func load() throws -> NASConfiguration {
    guard FileManager.default.fileExists(atPath: configurationURL.path) else { return NASConfiguration() }
    let value = try JSONDecoder().decode(NASConfiguration.self, from: Data(contentsOf: configurationURL))
    guard value.version == 1 else { throw NASError.incompatibleStore }
    return value
  }

  func save(_ configuration: NASConfiguration) throws { try write(configuration, to: configurationURL) }
  func save(_ index: NASIndex, for server: UUID) throws { try write(index, to: indexURL(server)) }
  func index(for server: NASServer) throws -> NASIndex {
    guard FileManager.default.fileExists(atPath: indexURL(server.id).path) else { throw NASError.noIndex }
    let value = try JSONDecoder().decode(NASIndex.self, from: Data(contentsOf: indexURL(server.id)))
    guard value.version == 1 else { throw NASError.incompatibleStore }
    guard value.serverID == server.serverID, value.userID == server.userID, value.baseURL == server.baseURL else { throw NASError.noIndex }
    return value
  }
  func removeIndex(for server: UUID) throws {
    let url = indexURL(server)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
  }
  private func indexURL(_ server: UUID) -> URL { directory.appendingPathComponent("index-\(server.uuidString).json") }
  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
  }
}
