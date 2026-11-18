"""Execute the production mpv window-scale handler with isolated state."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
source = (root / 'iina/PlayerCore.swift').read_text()
start = source.index('  func windowScaleChanged()')
a = source.index('{', start)
level, end = 1, a + 1
while level:
    level += (source[end] == '{') - (source[end] == '}')
    end += 1
code = '''import Foundation
struct Preference {
  enum Key { case lockPlayerWindowSize }
  static func bool(for key: Key) -> Bool { true }
}
struct MPVOption { struct Window { static let windowScale = "window-scale" } }
class Window {
  var loaded = true
  var scales: [Double] = []
  func setWindowScale(_ scale: Double) { scales.append(scale) }
}
struct State { var active = true }
struct Info { var state = State(); var cachedWindowScale = 1.0 }
struct MPV { var scale = 1.5; func getDouble(_ property: String) -> Double { scale } }
class Player {
  let mainWindow = Window()
  var info = Info(), mpv = MPV()
''' + source[start:end] + '''
}
let player = Player()
player.windowScaleChanged()
precondition(player.mainWindow.scales == [1.5], "Manual scaling must work with size lock enabled")
player.info.cachedWindowScale = 1.5
player.windowScaleChanged()
precondition(player.mainWindow.scales.count == 1, "Window feedback must not trigger another resize")
player.info.state.active = false
player.mpv.scale = 2
player.windowScaleChanged()
precondition(player.mainWindow.scales.count == 1)
print("PASS: manual window scaling with size lock, feedback suppression and idle guard")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(code)
    subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
