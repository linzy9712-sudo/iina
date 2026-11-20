"""Exercise the production first-server form save using isolated AppKit controls."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'iina/NAS/SettingsPageNAS.swift').read_text()
start = source.index('  @discardableResult private func saveServerFields()')
end = source.index('\n  private func run(', start)
method = source[start:end].replace('private func', 'func')
code = '''import Cocoa
struct Credentials {
  var removals = 0
  mutating func remove(_ server: NASServer) throws { removals += 1 }
}
final class Probe {
  var configuration = NASConfiguration()
  var credentials = Credentials()
  let servers = NSPopUpButton()
  let name = NSTextField(), address = NSTextField(), username = NSTextField()
  let password = NSSecureTextField()
  var selectedServer: NASServer? {
    configuration.servers.indices.contains(servers.indexOfSelectedItem)
      ? configuration.servers[servers.indexOfSelectedItem] : nil
  }
  func persist(_ updated: NASConfiguration) throws { configuration = updated }
''' + method + '''
}
@main struct ServerSetupRegression {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let p = Probe()
    p.name.stringValue = "NAS"
    p.address.stringValue = "http://nas.invalid:8097"
    p.username.stringValue = " user "
    p.password.stringValue = "synthetic-password"
    let first = try p.saveServerFields()
    precondition(p.configuration.servers.count == 1 && p.selectedServer?.id == first.id)
    precondition(first.username == "user" && first.name == "NAS")
    precondition(p.password.stringValue == "synthetic-password")
    let repeated = try p.saveServerFields()
    precondition(repeated.id == first.id && p.configuration.servers.count == 1)
    p.configuration.servers[0].userID = "user-id"
    p.configuration.servers[0].serverID = "server-id"
    p.name.stringValue = "Renamed"
    let renamed = try p.saveServerFields()
    precondition(renamed.userID == "user-id" && p.credentials.removals == 1)
    p.address.stringValue = "http://other.invalid:8097"
    let moved = try p.saveServerFields()
    precondition(moved.userID == nil && moved.serverID == nil && p.credentials.removals == 2)
    precondition(p.configuration.servers.count == 1)
    let empty = Probe()
    empty.address.stringValue = "not a URL"
    do {
      _ = try empty.saveServerFields()
      fatalError("Invalid URL accepted")
    } catch NASError.invalidURL { }
    precondition(empty.configuration.servers.isEmpty)
    do {
      _ = try JellyfinCredentialStore().read(first)
      fatalError("Unsigned server accepted")
    } catch NASError.signInRequired { }
    print("PASS: first-server creation, password preservation, repeated save, rename, address change, invalid URL and sign-in-required error")
  }
}
'''
with tempfile.TemporaryDirectory(prefix='iina-server-setup-') as directory:
    script = Path(directory) / 'ServerSetup.swift'
    binary = Path(directory) / 'server-setup'
    script.write_text(code)
    subprocess.run(['swiftc', '-parse-as-library',
                    str(root / 'iina/NAS/NASModels.swift'),
                    str(root / 'iina/NAS/JellyfinClient.swift'),
                    str(root / 'iina/NAS/JellyfinCredentialStore.swift'),
                    str(script), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
