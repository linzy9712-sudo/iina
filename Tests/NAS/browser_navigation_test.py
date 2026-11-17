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
final class Probe: NSObject, NSTableViewDelegate, NSTableViewDataSource {
 struct Row { var title: String; var folder: String? }
 struct Location { var folder: String?; var parents: [String?]; var names: [String]; var query: String }
 var folder: String?; var parents: [String?] = []; var folderNames: [String] = []
 let search = NSSearchField()
 var backHistory: [Location] = [], forwardHistory: [Location] = []
 var location: Location { Location(folder: folder, parents: parents, names: folderNames, query: search.stringValue) }
 func refresh() {}
 let backButton=NSButton(), forwardButton=NSButton()
 let listScroll=NSScrollView(), columnsScroll=NASColumnsScrollView(), columnsStack=NSStackView()
 let content=NSView(frame:NSRect(x:0,y:0,width:700,height:300)), table=NSTableView()
 var rebuildingColumns=false, columnsVisible=true
 weak var selectedTable:NSTableView?
 var columnRows:[[Row]]=[], cachedRows:[String:[Row]]=[:], rows:[Row]=[]
 @objc func columnClicked(_ sender:NSTableView) {}
 @objc func columnDoubleClicked(_ sender:NSTableView) {}
 func numberOfRows(in tableView:NSTableView)->Int { columnRows[tableView.tag].count }
'''+ '\n'.join(method(m) for m in methods)+'''
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
'''
with tempfile.TemporaryDirectory(prefix='iina-navigation-') as directory:
 script=Path(directory)/'NavigationRegression.swift'
 script.write_text(code)
 subprocess.run(['swift',str(script)],check=True)
