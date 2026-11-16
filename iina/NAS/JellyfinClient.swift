import Foundation

/// Redirects are rejected so credentials cannot be forwarded to another origin.
private final class JellyfinRedirectPolicy: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

final class JellyfinClient {
  struct User: Decodable { let Id: String }
  struct Login: Decodable { let AccessToken: String; let ServerId: String; let User: User }
  struct SystemInfo: Decodable { let Id: String }
  struct Item: Decodable {
    let Id: String
    let Name: String?
    let Path: String?
    let IsFolder: Bool?
    let MediaType: String?
    let ParentId: String?
    let RunTimeTicks: Int64?
    let MediaSources: [Source]?
  }
  struct Source: Decodable { let Id: String?; let Path: String? }
  struct Page: Decodable { let Items: [Item]; let TotalRecordCount: Int }
  private let session: URLSession
  let deviceID: String

  init(deviceID: String, session: URLSession? = nil) {
    self.deviceID = deviceID
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 120
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    self.session = session ?? URLSession(configuration: configuration, delegate: JellyfinRedirectPolicy(), delegateQueue: nil)
  }
  deinit { session.invalidateAndCancel() }

  static func serverURL(_ text: String) throws -> URL {
    guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
          let url = components.url else { throw NASError.invalidURL }
    return url
  }

  func login(baseURL: URL, username: String, password: String) async throws -> Login {
    let body = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
    let login: Login = try await request(baseURL, path: "Users/AuthenticateByName", body: body)
    guard !login.AccessToken.isEmpty, !login.ServerId.isEmpty, !login.User.Id.isEmpty else { throw NASError.invalidResponse }
    return login
  }

  func test(server: NASServer, token: String) async throws {
    let system: SystemInfo = try await request(server.baseURL, path: "System/Info", token: token)
    guard system.Id == server.serverID else { throw NASError.authentication }
    let user: User = try await request(server.baseURL, path: "Users/Me", token: token)
    guard user.Id == server.userID else { throw NASError.authentication }
  }

  /// A complete successful refresh replaces the snapshot, removing moved/deleted items.
  /// Failed or cancelled refreshes never replace the last usable snapshot.
  func index(server: NASServer, token: String, progress: @escaping (Int, Int) -> Void) async throws -> NASIndex {
    guard let userID = server.userID, let serverID = server.serverID else { throw NASError.authentication }
    try await test(server: server, token: token)
    var offset = 0
    var media: [NASMedia] = []
    var seen = Set<String>()
    var missing = 0
    var expectedTotal: Int?
    while true {
      try Task.checkCancellation()
      let page: Page = try await request(server.baseURL, path: "Items", token: token, query: [
        URLQueryItem(name: "UserId", value: userID), URLQueryItem(name: "Recursive", value: "true"),
        URLQueryItem(name: "MediaTypes", value: "Video"),
        URLQueryItem(name: "Fields", value: "Path,MediaSources,ParentId"),
        URLQueryItem(name: "SortBy", value: "SortName"), URLQueryItem(name: "SortOrder", value: "Ascending"),
        URLQueryItem(name: "StartIndex", value: String(offset)), URLQueryItem(name: "Limit", value: "500")])
      guard page.TotalRecordCount >= 0 else { throw NASError.invalidResponse }
      if let expectedTotal, expectedTotal != page.TotalRecordCount { throw NASError.invalidResponse }
      expectedTotal = page.TotalRecordCount
      if page.Items.isEmpty {
        guard offset >= page.TotalRecordCount else { throw NASError.invalidResponse }
        break
      }
      for item in page.Items {
        guard !item.Id.isEmpty, seen.insert(item.Id).inserted else { throw NASError.invalidResponse }
        let sources = (item.MediaSources ?? []).filter { $0.Path?.hasPrefix("/") == true }
        var paths = Set<String>()
        for source in sources {
          guard let path = source.Path else { continue }
          // Keep different source IDs as separate candidates; never overwrite ambiguity.
          media.append(NASMedia(itemID: item.Id, sourceID: source.Id, path: path,
                                title: item.Name ?? URL(fileURLWithPath: path).lastPathComponent,
                                parentID: item.ParentId, durationTicks: item.RunTimeTicks))
          paths.insert(path)
        }
        if let path = item.Path, path.hasPrefix("/"), !paths.contains(path) {
          media.append(NASMedia(itemID: item.Id, sourceID: nil, path: path,
                                title: item.Name ?? URL(fileURLWithPath: path).lastPathComponent,
                                parentID: item.ParentId, durationTicks: item.RunTimeTicks))
        } else if sources.isEmpty && item.Path?.hasPrefix("/") != true { missing += 1 }
      }
      offset += page.Items.count
      progress(offset, page.TotalRecordCount)
      if offset >= page.TotalRecordCount { break }
    }
    try Task.checkCancellation()
    if media.isEmpty && missing > 0 { throw NASError.missingPaths }
    return NASIndex(serverID: serverID, userID: userID, baseURL: server.baseURL,
                    refreshedAt: Date(), missingPaths: missing, media: media)
  }

  func request<T: Decodable>(_ baseURL: URL, path: String, token: String? = nil,
                                     query: [URLQueryItem] = [], body: Data? = nil, method: String? = nil) async throws -> T {
    var components = URLComponents(url: path.isEmpty ? baseURL : baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { components.queryItems = (components.queryItems ?? []) + query }
    guard let url = components.url else { throw NASError.invalidURL }
    var request = URLRequest(url: url)
    request.httpMethod = method ?? (body == nil ? "GET" : "POST")
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    request.setValue("MediaBrowser Client=\"IINA\", Device=\"Mac\", DeviceId=\"\(deviceID)\", Version=\"1.0\"", forHTTPHeaderField: "Authorization")
    if let token { request.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
    let data: Data
    let response: URLResponse
    do { (data, response) = try await session.data(for: request) }
    catch {
      if Task.isCancelled { throw CancellationError() }
      // Surface only the numeric code, never URLs, response bodies or credentials.
      let failure = error as NSError
      if failure.domain == NSURLErrorDomain { throw NASError.transportCode(failure.code) }
      throw NASError.transport
    }
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else { throw NASError.invalidResponse }
    guard http.statusCode != 401 && http.statusCode != 403 else { throw NASError.authentication }
    guard (200..<300).contains(http.statusCode) else { throw NASError.http(http.statusCode) }
    if T.self == Data.self { return data as! T }
    if T.self == JellyfinEmptyResponse.self { return JellyfinEmptyResponse() as! T }
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw NASError.invalidResponse }
  }
}

struct JellyfinEmptyResponse: Decodable {}
