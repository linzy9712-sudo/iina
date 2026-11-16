import Foundation

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw NSError(domain: "NASRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func fails(_ label: String, _ operation: () throws -> Void) throws {
  do { try operation() } catch { return }
  throw NSError(domain: "NASRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: label])
}

final class MockHTTP: URLProtocol {
  static var handler: ((URLRequest) throws -> (Int, String))!
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, body) = try Self.handler(request)
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

@main struct NASRegression {
  static func main() async throws {
    let server = NASServer(name: "Test", baseURL: URL(string: "https://nas.invalid/jellyfin")!, serverID: "s1", userID: "u1")
    let root = NASPathMapping(server: server.id, localRoot: "/Volumes/NAS/电影", remoteRoot: "/media/movies")
    let specific = NASPathMapping(server: server.id, localRoot: "/Volumes/NAS/电影/科幻", remoteRoot: "/media/scifi")
    let path = "/Volumes/NAS/电影/科幻/电影 10.mkv"
    let mapped = try NASPathMapper.map(path, rules: [root, specific])
    try require(mapped.1 == "/media/scifi/电影 10.mkv", "longest prefix and Unicode")
    try fails("component boundary") { _ = try NASPathMapper.map("/Volumes/NAS/电影备份/a.mkv", rules: [root]) }
    try fails("traversal") { _ = try NASPathMapper.map("/Volumes/NAS/电影/../a.mkv", rules: [root]) }
    try fails("ambiguous mapping") { _ = try NASPathMapper.map(path, rules: [specific, specific]) }
    var higher = specific; higher.priority = 10; higher.remoteRoot = "/priority"
    try require(tryMap(path, [specific, higher]) == "/priority/电影 10.mkv", "priority")
    let media = NASMedia(itemID: "i1", sourceID: "m1", path: mapped.1, title: "Film", parentID: nil, durationTicks: nil)
    let index = NASIndex(serverID: "s1", userID: "u1", baseURL: server.baseURL, refreshedAt: Date(), missingPaths: 0, media: [media])
    try require(try NASPathMapper.match(mapped.1, in: index, caseSensitive: true).itemID == "i1", "identity")
    var conflict = index.media
    conflict.append(NASMedia(itemID: "i2", sourceID: nil, path: mapped.1, title: "Other", parentID: nil, durationTicks: nil))
    let ambiguous = NASIndex(serverID: "s1", userID: "u1", baseURL: server.baseURL, refreshedAt: Date(), missingPaths: 0, media: conflict)
    try fails("ambiguous index") { _ = try NASPathMapper.match(mapped.1, in: ambiguous, caseSensitive: true) }
    try require(try NASPathMapper.key("/café/a", caseSensitive: true) == NASPathMapper.key("/cafe\u{301}/a", caseSensitive: true), "Unicode normalization")
    try require(try NASPathMapper.key("/A/MOVIE", caseSensitive: false) == NASPathMapper.key("/a/movie", caseSensitive: false), "explicit case folding")
    for invalid in ["file:///tmp/a", "https://user:secret@nas", "https://nas?api_key=secret", "https://nas/#x"] {
      try fails("invalid server URL") { _ = try JellyfinClient.serverURL(invalid) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NASStore(directory: directory)
    var configuration = NASConfiguration(); configuration.servers = [server]; configuration.mappings = [root]
    try store.save(configuration); try store.save(index, for: server.id)
    try require(try store.load().servers == [server], "configuration round trip")
    try require(try store.index(for: server).media == [media], "offline index round trip")
    var otherUser = server; otherUser.userID = "u2"
    try fails("account isolation") { _ = try store.index(for: otherUser) }
    var otherAddress = server; otherAddress.baseURL = URL(string: "https://other.invalid")!
    try fails("address isolation") { _ = try store.index(for: otherAddress) }

    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockHTTP.self]
    let client = JellyfinClient(deviceID: "device", session: URLSession(configuration: config))
    var calls = 0
    MockHTTP.handler = { request in
      try require(request.url!.path.hasPrefix("/jellyfin/"), "reverse-proxy base path")
      try require(request.value(forHTTPHeaderField: "X-Emby-Token") == "secret-token", "authentication header")
      try require(!request.url!.absoluteString.contains("secret-token"), "token absent from URL")
      if request.url!.path.hasSuffix("System/Info") { return (200, "{\"Id\":\"s1\"}") }
      if request.url!.path.hasSuffix("Users/Me") { return (200, "{\"Id\":\"u1\"}") }
      calls += 1
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      let offset = query.first { $0.name == "StartIndex" }!.value!
      if offset == "0" { return (200, "{\"Items\":[{\"Id\":\"a\",\"Path\":\"/media/a.mkv\"}],\"TotalRecordCount\":2}") }
      return (200, "{\"Items\":[{\"Id\":\"b\",\"MediaSources\":[{\"Id\":\"v1\",\"Path\":\"/media/b.mkv\"}]}],\"TotalRecordCount\":2}")
    }
    let fetched = try await client.index(server: server, token: "secret-token") { _, _ in }
    try require(calls == 2 && fetched.media.count == 2, "paginated snapshot")
    let data = try JSONEncoder().encode(fetched)
    try require(!String(decoding: data, as: UTF8.self).contains("secret-token"), "no token persistence")
    MockHTTP.handler = { _ in (401, "secret response body") }
    do {
      try await client.test(server: server, token: "secret-token")
      throw NSError(domain: "Expected auth failure", code: 1)
    } catch NASError.authentication { }
    MockHTTP.handler = { request in
      if request.url!.path.hasSuffix("System/Info") { return (200, "{\"Id\":\"s1\"}") }
      if request.url!.path.hasSuffix("Users/Me") { return (200, "{\"Id\":\"u1\"}") }
      return (200, "{\"Items\":[],\"TotalRecordCount\":10}")
    }
    do {
      _ = try await client.index(server: server, token: "secret-token") { _, _ in }
      throw NSError(domain: "Expected incomplete-page failure", code: 1)
    } catch NASError.invalidResponse { }
    try require(try store.index(for: server).media == [media], "failed refresh preserves old snapshot")
    print("PASS: path mapping, ambiguity, Unicode, priority, URL validation, persistence, account/address isolation, pagination, authentication and incomplete-page handling")
  }
  static func tryMap(_ path: String, _ rules: [NASPathMapping]) -> String? { try? NASPathMapper.map(path, rules: rules).1 }
}
