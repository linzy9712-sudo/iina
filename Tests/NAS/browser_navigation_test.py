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
methods=['  private func rememberLocation()', '  private func restore(', '  @objc private func goBack()', '  @objc private func goForward()', '  @objc private func jumpToFolder(', '  @objc private func columnClicked(', '  private func navigate(', '  private func renderColumns()', '  private func selectedRowsForAppend()', '  private func data(for']
methods += ['  private func column(for', '  private func addColumn(', '  private func removeColumns(', '  private func updateColumnRows(',
            '  private func showRowsWhileLoading()', '  @objc private func up()', '  @objc private func resetFolder()']
scroll_type = s[s.index('final class NASColumnsScrollView:'):s.index('final class NASBrowserWindowController:')]
column_types = s[s.index('  private struct Row:'):s.index('  private unowned let player:')].replace('private struct', 'struct')
code='import Cocoa\n' + scroll_type + '''
// AppKit normally reads the rest of a gesture from WindowServer. In this fixture
// the test itself delivers each phase synchronously to the table's responder chain.
final class FixtureStack: NSStackView {
 override class var isCompatibleWithResponsiveScrolling: Bool { false }
}
final class FixtureTable: NSTableView {
 override class var isCompatibleWithResponsiveScrolling: Bool { false }
 var clickedFolderRow: Int?
 override var clickedRow: Int { clickedFolderRow ?? super.clickedRow }
 private(set) var reloads = 0
 override func reloadData() { reloads += 1; super.reloadData() }
}
struct NASQueueEntry { let itemID: String?; let sourceID: String?; var title: String? }
final class Probe: NSObject, NSTableViewDelegate, NSTableViewDataSource {
''' + column_types + '''
 struct Location { var folder: String?; var parents: [String?]; var names: [String]; var query: String }
 var folder: String?; var parents: [String?] = []; var folderNames: [String] = []
 let search = NSSearchField()
 var backHistory: [Location] = [], forwardHistory: [Location] = []
 var location: Location { Location(folder: folder, parents: parents, names: folderNames, query: search.stringValue) }
 var simulateLoading = false
 func refresh() { if simulateLoading { showRowsWhileLoading() } }
 func cancelImport() {}
 let backButton=NSButton(), forwardButton=NSButton()
 let listScroll=NSScrollView(), columnsScroll=NASColumnsScrollView(), columnsStack=FixtureStack()
 let content=NSView(frame:NSRect(x:0,y:0,width:700,height:300)), table=NSTableView()
 var rebuildingColumns=false, columnsVisible=true
 var columns: [Column] = []
 weak var selectedTable:NSTableView?
 var cachedRows:[String:[Row]]=[:], rows:[Row]=[]
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
precondition(p.columns.count==3 && p.columnsStack.arrangedSubviews.count==3)
precondition(p.columns[0].rows[0].folder=="a" && p.columns[1].rows[0].folder=="c" && p.columns[2].rows[0].title=="movie")
var queuedFolders=p.selectedRowsForAppend().compactMap(\.folder)
precondition(queuedFolders == ["c"])
p.cachedRows["c"]=[.init(title:"D",folder:"d")]
p.rows=p.cachedRows["c"]!;p.renderColumns()
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

// Scroll to a folder far below the first screen, then open it just as a single click does.
browser.simulateLoading = true
func showFolderRows(_ values: [Probe.Row]) {
  browser.cachedRows[browser.folder ?? ""] = values
  browser.rows = values
  browser.renderColumns()
  outer.layoutSubtreeIfNeeded()
}
func clickFolder(_ row: Int, in list: FixtureTable) {
  list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
  list.clickedFolderRow = row
  browser.columnClicked(list)
  outer.layoutSubtreeIfNeeded()
}
func scrollToFolder(_ row: Int, in list: FixtureTable) -> CGFloat {
  list.scrollRowToVisible(row)
  let offset = list.enclosingScrollView!.documentVisibleRect.minY
  precondition(offset > 500 && list.visibleRect.intersects(list.rect(ofRow: row)))
  return offset
}
let folders = (0..<120).map { Probe.Row(title: "Folder \($0)", folder: "parent-\($0)") }
showFolderRows(folders)
let parentScroll = browser.columnsStack.arrangedSubviews.last! as! NSScrollView
let parentList = parentScroll.documentView as! FixtureTable
let parentDepth = parentList.tag
let parentY = scrollToFolder(90, in: parentList)
let parentReloads = parentList.reloads
clickFolder(90, in: parentList)
func checkParent(_ row: Int) {
  let visible = browser.columnsStack.arrangedSubviews[parentDepth] as! NSScrollView
  precondition(abs(visible.documentVisibleRect.minY - parentY) < 1, "Opening a child reset the parent scroll position")
  precondition(visible === parentScroll && parentList.selectedRow == row, "Keep the parent table and folder selection")
}
checkParent(90)
let subfolders = (0..<120).map { Probe.Row(title: "Subfolder \($0)", folder: "child-\($0)") }
showFolderRows(subfolders)
let childScroll = browser.columnsStack.arrangedSubviews.last! as! NSScrollView
let childList = childScroll.documentView as! FixtureTable
let childY = scrollToFolder(76, in: childList)
clickFolder(76, in: childList)
var video = NASQueueEntry(itemID: "video", sourceID: "main", title: "Original title")
showFolderRows([.init(title: "video.mkv", entry: video)])
let videoList = browser.columns.last!.table as! FixtureTable
let videoReloads = videoList.reloads
video.title = "Updated title"
showFolderRows([.init(title: "video.mkv", entry: video)])
precondition(browser.data(for: videoList).first?.entry?.title == "Updated title" && videoList.reloads == videoReloads,
             "Refresh playback metadata when the displayed filenames are unchanged")
checkParent(90)
precondition(browser.columnsStack.arrangedSubviews[childList.tag] === childScroll &&
             abs(childScroll.documentVisibleRect.minY - childY) < 1, "Keep both ancestor viewports after loading")
clickFolder(89, in: parentList)
checkParent(89)
precondition(browser.folder == "parent-89" && browser.columns.last?.rows.isEmpty == true &&
             browser.selectedRowsForAppend().compactMap(\.folder) == ["parent-89"], "Replace descendants on branch change")
precondition(parentList.reloads == parentReloads, "Child navigation must not reload the parent list")
browser.up()
checkParent(89)
precondition(parentList.numberOfRows == folders.count, "Show the retained parent's rows while revalidating")
showFolderRows([.init(title: "Earlier folder", folder: "parent-new")] + folders)
checkParent(90)
precondition(browser.selectedRowsForAppend().compactMap(\.folder) == ["parent-89"], "Keep the folder selected by identity after insertion")
browser.goBack()
checkParent(90)
browser.resetFolder()
precondition(browser.columns.count == 1 && browser.columns[0].rows.isEmpty && browser.data(for: parentList).isEmpty,
             "A server or library-mode change must discard the old columns and their rows")
print("PASS: deeply scrolled parents, sibling navigation, return during loading, selection and server reset")
'''
with tempfile.TemporaryDirectory(prefix='iina-navigation-') as directory:
 script=Path(directory)/'NavigationRegression.swift'
 script.write_text(code)
 subprocess.run(['swift',str(script)],check=True,timeout=45)
