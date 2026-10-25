import SwiftUI
import AppKit

struct WorkspaceEntry: Identifiable {
    let url:URL
    let directory:Bool
    var id:String { url.path }
    var name:String { url.lastPathComponent }
}
enum WorkspaceDirectory {
    static func list(_ url:URL, hidden:Bool) throws -> [WorkspaceEntry] {
        let files=try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isDirectoryKey],options:hidden ? [] : [.skipsHiddenFiles])
        return files.map { WorkspaceEntry(url:$0,directory:(try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) ?? false) }.sorted {
            if $0.directory != $1.directory { return $0.directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
@MainActor
final class FileDirectoryModel:ObservableObject {
    @Published var entries:[WorkspaceEntry]=[]
    @Published var error:String?
    @Published var loading=false
    func load(_ url:URL, hidden:Bool) async {
        loading=true
        do {
            let entries=try await Task.detached(priority:.utility) { try WorkspaceDirectory.list(url,hidden:hidden) }.value
            self.entries=entries;error=nil
        } catch { self.error=error.localizedDescription }
        loading=false
    }
}
struct FilePreviewRequest:Identifiable { let url:URL;var id:String { url.path } }

struct WorkspaceFileBrowser:View {
    let root:URL
    let preview:(URL)->Void
    @State private var hidden=false
    @State private var revision=0
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text(root.lastPathComponent).font(.system(size:12,weight:.medium)).lineLimit(1)
                Spacer()
                Menu {
                    Toggle("显示隐藏文件",isOn:$hidden)
                    Button("在 Finder 中打开") { NSWorkspace.shared.open(root) }
                } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button { revision += 1 } label: { Image(systemName:"arrow.clockwise") }.buttonStyle(PiButtonStyle(horizontalPadding:4,verticalPadding:4)).help("刷新文件")
            }.padding(.horizontal,15)
            ScrollView {
                FileDirectoryRows(url:root,hidden:hidden,ancestors:[],preview:preview).id(root.path + "\(hidden)-\(revision)")
                    .padding(.horizontal,9)
            }
        }.padding(.top,12)
    }
}
private struct FileDirectoryRows:View {
    let url:URL
    let hidden:Bool
    let ancestors:Set<String>
    let preview:(URL)->Void
    @StateObject private var model=FileDirectoryModel()
    var body:some View {
        LazyVStack(alignment:.leading,spacing:1) {
            if model.loading { ProgressView().controlSize(.mini).padding(8) }
            if let error=model.error { Text(error).font(.system(size:11)).foregroundStyle(Theme.secondary).padding(8) }
            ForEach(model.entries) { entry in
                FileTreeRow(entry:entry,hidden:hidden,ancestors:ancestors.union([url.resolvingSymlinksInPath().path]),preview:preview)
            }
            if !model.loading,model.error == nil,model.entries.isEmpty { Text("空文件夹").font(.system(size:11)).foregroundStyle(Theme.secondary).padding(8) }
        }.task { await model.load(url,hidden:hidden) }
    }
}
private struct FileTreeRow:View {
    let entry:WorkspaceEntry
    let hidden:Bool
    let ancestors:Set<String>
    let preview:(URL)->Void
    @State private var expanded=false
    private var canExpand:Bool { entry.directory && !ancestors.contains(entry.url.resolvingSymlinksInPath().path) }
    var body:some View {
        VStack(alignment:.leading,spacing:1) {
            Button {
                if canExpand { expanded.toggle() }
                else if !entry.directory { preview(entry.url) }
            } label: {
                HStack(spacing:6) {
                    Group { if canExpand { Image(systemName:"chevron.right").font(.system(size:8)).rotationEffect(.degrees(expanded ? 90 : 0)) } else { Color.clear } }.frame(width:9)
                    Image(systemName:entry.directory ? "folder" : "doc.text").font(.system(size:12)).foregroundStyle(Theme.secondary)
                    Text(entry.name).font(.system(size:12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength:0)
                }.padding(.horizontal,5).frame(height:27).contentShape(Rectangle())
            }.buttonStyle(PiButtonStyle(kind:.row,horizontalPadding:0,verticalPadding:0)).help(entry.url.path)
                .contextMenu {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                    if !entry.directory { Button("使用默认应用打开") { NSWorkspace.shared.open(entry.url) } }
                }
            if expanded,canExpand { FileDirectoryRows(url:entry.url,hidden:hidden,ancestors:ancestors,preview:preview).padding(.leading,14) }
        }
    }
}

struct FilePreviewContents {
    let text:String
    let truncated:Bool
    static func read(_ url:URL) throws -> FilePreviewContents {
        let handle=try FileHandle(forReadingFrom:url);defer { try? handle.close() }
        let data=try handle.read(upToCount:256*1024+1) ?? Data()
        guard !data.prefix(4096).contains(0) else { throw PiError.message("这是二进制文件，请使用默认应用打开。") }
        let prefix=data.prefix(256*1024)
        let text=data.count > 256*1024 ? (0...3).compactMap({ String(data:prefix.dropLast($0),encoding:.utf8) }).first : String(data:prefix,encoding:.utf8)
        guard let text else { throw PiError.message("无法以 UTF-8 文本预览，可使用默认应用打开。") }
        return .init(text:text,truncated:data.count > 256*1024)
    }
}
private struct ReadOnlyFileText:NSViewRepresentable {
    let text:String
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true
        let view=NSTextView();view.isEditable=false;view.isSelectable=true;view.isRichText=false
        view.font = .monospacedSystemFont(ofSize:12,weight:.regular);view.textColor = .labelColor
        view.drawsBackground=false;scroll.drawsBackground=false
        view.isVerticallyResizable=true;view.isHorizontallyResizable=true
        view.textContainer?.widthTracksTextView=false;view.textContainer?.containerSize=NSSize(width:100000,height:CGFloat.greatestFiniteMagnitude)
        view.textContainerInset=NSSize(width:16,height:12);scroll.documentView=view
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) { (scroll.documentView as? NSTextView)?.string=text }
}
struct WorkspaceFilePreview:View {
    let url:URL
    @Environment(\.dismiss) private var dismiss
    @State private var contents:FilePreviewContents?
    @State private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                VStack(alignment:.leading,spacing:3) { Text(url.lastPathComponent).font(.system(size:16,weight:.medium));Text(url.path).font(.system(size:11)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
                Button("外部打开") { NSWorkspace.shared.open(url) };Button("关闭") { dismiss() }
            }
            if let contents {
                if contents.truncated { Text("只读预览前 256 KB；外部打开可查看完整文件。 ").font(.system(size:11)).foregroundStyle(Theme.secondary) }
                ReadOnlyFileText(text:contents.text).frame(maxWidth:.infinity,maxHeight:.infinity).background(Theme.code,in:RoundedRectangle(cornerRadius:8))
            } else if let error { Text(error).foregroundStyle(Theme.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
            else { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity) }
        }.padding(20).frame(width:740,height:520)
            .task {
                do { contents=try await Task.detached(priority:.utility) { try FilePreviewContents.read(url) }.value }
                catch { self.error=error.localizedDescription }
            }
    }
}
