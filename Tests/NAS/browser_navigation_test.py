"""Exercise production navigation methods in an isolated AppKit fixture."""
from pathlib import Path
import subprocess, tempfile
s=(Path(__file__).resolve().parents[2] / 'iina/NAS/NASBrowserWindowController.swift').read_text()
def method(name):
 start=s.index(name);a=s.index('{',start);level=1;i=a+1
 while level:
  if s[i]=='{':level+=1
  if s[i]=='}':level-=1
  i+=1
 return s[start:i].replace('private func','func')
methods=['  private func rememberLocation()', '  private func restore(', '  @objc private func goBack()', '  @objc private func goForward()', '  @objc private func jumpToFolder(', '  private func navigate(', '  private func renderColumns()', '  private func selectedRowsForAppend()', '  private func data(for']
scroll_type = s[s.index('final class NASColumnsScrollView:'):s.index('final class NASBrowserWindowController:')]
code='import Cocoa\n' + scroll_type + '''
// AppKit normally reads the rest of a gesture from WindowServer. In this fixture
// the test itself delivers each phase synchronously to the table's responder chain.
final class FixtureStack: NSStackView {
 override class var isCompatibleWithResponsiveScrolling: Bool { false }
}
final class FixtureTable: NSTableView {
 override class var isCompatibleWithResponsiveScrolling: Bool { false }
}
final class Probe: NSObject, NSTableViewDelegate, NSTableViewDataSource {
 struct Row { var title: String; var folder: String? }
 struct Location { var folder: String?; var parents: [String?]; var names: [String]; var query: String }
 var folder: String?; var parents: [String?] = []; var folderNames: [String] = []
 let search = NSSearchField()
 var backHistory: [Location] = [], forwardHistory: [Location] = []
 var location: Location { Location(folder: folder, parents: parents, names: folderNames, query: search.stringValue) }
 func refresh() {}
 let backButton=NSButton(), forwardButton=NSButton()
 let listScroll=NSScrollView(), columnsScroll=NASColumnsScrollView(), columnsStack=FixtureStack()
 let content=NSView(frame:NSRect(x:0,y:0,width:700,height:300)), table=NSTableView()
 var rebuildingColumns=false, columnsVisible=true
 var renderedColumnPath: [String?] = []
 weak var selectedTable:NSTableView?
 var columnRows:[[Row]]=[], cachedRows:[String:[Row]]=[:], rows:[Row]=[]
 @objc func columnClicked(_ sender:NSTableView) {}
 @objc func columnDoubleClicked(_ sender:NSTableView) {}
 func numberOfRows(in tableView:NSTableView)->Int { data(for: tableView).count }
 func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
   NSTextField(labelWithString: data(for: tableView)[row].title)
 }
'''+ '\n'.join(method(m) for m in methods).replace('let list = NSTableView()', 'let list = FixtureTable()')+r'''
}
let app=NSApplication.shared
let p=Probe()
p.navigate(to:.init(title:"A",folder:"a"));p.navigate(to:.init(title:"B",folder:"b"))
precondition(p.parents.count==2 && p.folder=="b")
p.navigate(to:.init(title:"B",folder:"b"));precondition(p.parents.count==2)
p.goBack();precondition(p.folder=="a" && p.forwardHistory.count==1)
p.goForward();precondition(p.folder=="b")
let root=NSButton();root.tag=0;p.jumpToFolder(root);precondition(p.folder==nil && p.parents.isEmpty)
p.goBack();precondition(p.folder=="b" && p.folderNames==["A","B"])
p.goBack();p.navigate(to:.init(title:"C",folder:"c"));precondition(p.forwardHistory.isEmpty)
p.cachedRows[""]=[.init(title:"A",folder:"a")]
p.cachedRows["a"]=[.init(title:"C",folder:"c")]
p.rows=[.init(title:"movie",folder:nil)]
p.columnsStack.orientation = .horizontal
p.columnsScroll.documentView = p.columnsStack
p.columnsScroll.hasHorizontalScroller = true
p.columnsScroll.setFrameSize(NSSize(width:700,height:300))
p.renderColumns()
precondition(p.columnRows.count==3 && p.columnsStack.arrangedSubviews.count==3)
precondition(p.columnRows[0][0].folder=="a" && p.columnRows[1][0].folder=="c" && p.columnRows[2][0].title=="movie")
var queuedFolders=p.selectedRowsForAppend().compactMap(\.folder)
precondition(queuedFolders == ["c"])
p.cachedRows["c"]=[.init(title:"D",folder:"d")]
p.navigate(to:.init(title:"D",folder:"d"));p.rows=[];p.renderColumns()
queuedFolders += p.selectedRowsForAppend().compactMap(\.folder)
precondition(queuedFolders == ["c","d"])
p.rows=[.init(title:"new movie",folder:nil)];p.renderColumns()
precondition(p.selectedRowsForAppend().compactMap(\.folder)==["d"])
p.goBack();p.rows=[.init(title:"movie",folder:nil)];p.renderColumns()
print("PASS: adding one folder then entering another retains the new append selection across loading and rendering")

for style in [NSScroller.Style.legacy, .overlay] {
 p.columnsScroll.scrollerStyle=style
 for height in [200.0,300.0,500.0] {
  p.columnsScroll.setFrameSize(NSSize(width:700,height:height))
  p.renderColumns();p.columnsScroll.tile();p.columnsStack.layoutSubtreeIfNeeded()
  precondition(abs(p.columnsStack.frame.height-p.columnsScroll.contentView.bounds.height)<0.5)
  precondition(p.columnsScroll.documentVisibleRect.contains(p.columnsStack.bounds.intersection(NSRect(x:p.columnsScroll.documentVisibleRect.minX,y:0,width:p.columnsScroll.documentVisibleRect.width,height:p.columnsStack.bounds.height))))
 }
}
print("PASS: column height fits viewport with legacy/overlay scrollbars at multiple window sizes")
p.columnsVisible=false;p.renderColumns();precondition(p.columnsScroll.isHidden && !p.listScroll.isHidden && p.folder=="c")
print("PASS: back/forward, root jump, branch invalidation, duplicate prevention, ancestor columns and view switching")

let browser = Probe()
let outer = browser.columnsScroll
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 676, height: 275),
                      styleMask: [.borderless], backing: .buffered, defer: false)
browser.columnsStack.orientation = .horizontal
browser.columnsStack.spacing = 0
browser.columnsStack.alignment = .top
outer.documentView = browser.columnsStack
window.contentView = outer
window.alphaValue = 0
window.animationBehavior = .none
window.orderBack(nil)
defer { window.orderOut(nil) }

func trackpadScroll(over view: NSView, x: Int32, y: Int32) {
  let point = window.convertPoint(toScreen: view.convert(NSPoint(x: view.visibleRect.midX, y: view.visibleRect.midY), to: nil))
  for phase in [CGScrollPhase.began, .changed, .ended] {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                     wheel1: phase == .ended ? 0 : y, wheel2: phase == .ended ? 0 : x, wheel3: 0)!
    cg.location = NSPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
    cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
    cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
    view.scrollWheel(with: NSEvent(cgEvent: cg)!)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
  }
}

for id in ["a", "b", "c", "d"] { browser.navigate(to: .init(title: id, folder: id)) }
browser.rows = (0..<80).map { .init(title: "Video \($0)") }
browser.renderColumns()
outer.layoutSubtreeIfNeeded()
let right = outer.documentVisibleRect.minX
precondition(right > 500, "Opening a deep folder should reveal the last column")
let inner = browser.columnsStack.arrangedSubviews.last! as! NSScrollView
let leaf = inner.documentView as! NSTableView
for style in [NSScroller.Style.legacy, .overlay] {
  inner.scrollerStyle = style
  inner.tile()
  let initialX = outer.documentVisibleRect.minX, initialY = inner.documentVisibleRect.minY
  trackpadScroll(over: leaf, x: 50, y: 0)
  let left = outer.documentVisibleRect.minX
  precondition(left < initialX - 5 && inner.documentVisibleRect.minY == initialY, "Swipe left over video rows")
  trackpadScroll(over: leaf, x: -20, y: 0)
  precondition(outer.documentVisibleRect.minX > left + 5, "Swipe right over video rows")
  let beforeVertical = outer.documentVisibleRect.minX
  trackpadScroll(over: leaf, x: 0, y: -30)
  precondition(inner.documentVisibleRect.minY > initialY + 5 && outer.documentVisibleRect.minX == beforeVertical,
               "Vertical scrolling should stay in the column")
}
let visibleX = outer.documentVisibleRect.minX
browser.rows.append(.init(title: "Later result"))
browser.renderColumns()
precondition(outer.documentVisibleRect.minX == visibleX && leaf.numberOfRows == 81,
             "Loading results should update the leaf without moving the user")
let bar = outer.horizontalScroller!
precondition(outer.scrollerStyle == .legacy && !bar.isHidden && bar.isEnabled && bar.knobProportion < 1,
             "Overflow needs a visible bottom scrollbar")
func dragThumb(by distance: CGFloat) {
  let knob = bar.rect(for: .knob)
  let center = NSPoint(x: knob.midX, y: knob.midY)
  precondition(outer.hitTest(bar.convert(center, to: outer.superview)) === bar, "Thumb must receive mouse hits")
  let start = bar.convert(center, to: nil)
  func mouse(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [],
                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                       context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
  }
  NSApp.postEvent(mouse(.leftMouseDragged, x: start.x + distance), atStart: false)
  NSApp.postEvent(mouse(.leftMouseUp, x: start.x + distance), atStart: false)
  bar.mouseDown(with: mouse(.leftMouseDown, x: start.x))
}
dragThumb(by: -90)
let afterDrag = outer.documentVisibleRect.minX
precondition(afterDrag < visibleX - 10, "Dragging the thumb left should reveal earlier folders")
dragThumb(by: 45)
precondition(outer.documentVisibleRect.minX > afterDrag + 10, "Dragging the thumb right should reveal later folders")
browser.navigate(to: .init(title: "e", folder: "e"))
browser.renderColumns()
precondition(outer.documentVisibleRect.minX > right, "New navigation should still reveal the new folder")
print("PASS: trackpad swipes over rows in both directions, vertical scrolling, loading position and bottom scrollbar")
'''
with tempfile.TemporaryDirectory(prefix='iina-navigation-') as directory:
 script=Path(directory)/'NavigationRegression.swift'
 script.write_text(code)
 subprocess.run(['swift',str(script)],check=True,timeout=45)
