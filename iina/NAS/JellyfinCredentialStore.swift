import Foundation
import Security

struct JellyfinCredentialStore {
  private func query(_ server: NASServer) throws -> [String: Any] {
    guard let user = server.userID, let serverID = server.serverID else { throw NASError.signInRequired }
    return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "IINA Jellyfin",
            kSecAttrAccount as String: "\(server.id.uuidString):\(serverID):\(user)"]
  }

  func read(_ server: NASServer) throws -> String {
    var query = try query(server)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status != errSecItemNotFound else { throw NASError.signInRequired }
    guard status == errSecSuccess else { throw NASError.keychain(status) }
    guard let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { throw NASError.authentication }
    return token
  }

  func write(_ token: String, for server: NASServer) throws {
    let query = try query(server)
    let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var addition = query.merging(attributes) { _, new in new }
      addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(addition as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw NASError.keychain(status) }
  }

  func remove(_ server: NASServer) throws {
    guard server.userID != nil, server.serverID != nil else { return }
    let status = SecItemDelete(try query(server) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw NASError.keychain(status) }
  }
}
