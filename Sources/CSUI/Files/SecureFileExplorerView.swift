import SwiftUI
import CSCore

public struct SecureFileExplorerView: View {

    @StateObject private var vm: FileExplorerViewModel
    @State private var showDLPAlert = false
    @State private var dlpMessage = ""

    public init(workspaceURL: URL) {
        _vm = StateObject(wrappedValue: FileExplorerViewModel(rootURL: workspaceURL))
    }

    public var body: some View {
        HSplitView {
            // Left: directory tree
            List(vm.rootItems, children: \.children, selection: $vm.selectedItem) { item in
                Label {
                    Text(item.name)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(item.isDirectory ? .blue : .secondary)
                }
                .tag(item)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180, maxWidth: 260)

            // Right: file detail / preview
            VStack(spacing: 0) {
                // Toolbar
                HStack {
                    Text(vm.selectedItem?.name ?? "Select a file")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()

                    if vm.selectedItem != nil {
                        Button("Open") { vm.openSelected() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                        Button("Share…") { vm.shareSelected() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .background(.bar)

                Divider()

                // DLP info banner
                if vm.dlpPolicyActive {
                    HStack(spacing: 8) {
                        Image(systemName: "watermark")
                            .foregroundStyle(.orange)
                        Text("Files are watermarked per corporate policy. Sharing is monitored.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.08))
                    Divider()
                }

                // File metadata / preview area
                if let item = vm.selectedItem {
                    FileDetailView(item: item)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No File Selected")
                            .font(.headline)
                        Text("Select a file to view its details.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Secure Files")
        .toolbar {
            ToolbarItem {
                Button {
                    vm.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear { vm.load() }
    }
}

// MARK: - File Item Model

struct FileItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var children: [FileItem]?

    var name: String        { url.lastPathComponent }
    var isDirectory: Bool   { children != nil }
    var fileExtension: String { url.pathExtension }

    var systemImage: String {
        if isDirectory { return "folder.fill" }
        switch fileExtension.lowercased() {
        case "pdf":                return "doc.richtext.fill"
        case "docx", "doc":       return "doc.fill"
        case "xlsx", "xls":       return "tablecells.fill"
        case "pptx", "ppt":       return "rectangle.on.rectangle.angled.fill"
        case "png", "jpg", "jpeg", "heic": return "photo.fill"
        case "zip", "tar", "gz":  return "archivebox.fill"
        default:                  return "doc.fill"
        }
    }
}

// MARK: - File Detail View

struct FileDetailView: View {
    let item: FileItem

    private var attrs: [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: item.url.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Icon
            HStack {
                Spacer()
                Image(systemName: item.systemImage)
                    .font(.system(size: 64))
                    .foregroundStyle(.blue.gradient)
                    .padding(20)
                Spacer()
            }

            // Metadata grid
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                metaRow("Name",     item.name)
                metaRow("Size",     formattedSize)
                metaRow("Modified", formattedDate)
                metaRow("Path",     item.url.deletingLastPathComponent().lastPathComponent)
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func metaRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var formattedSize: String {
        guard let size = attrs?[.size] as? Int64 else { return "–" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var formattedDate: String {
        guard let date = attrs?[.modificationDate] as? Date else { return "–" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - ViewModel

final class FileExplorerViewModel: ObservableObject {
    @Published var rootItems: [FileItem] = []
    @Published var selectedItem: FileItem?
    @Published var dlpPolicyActive = true

    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func load() {
        rootItems = buildTree(url: rootURL, depth: 0)
    }

    func refresh() { load() }

    func openSelected() {
        guard let item = selectedItem else { return }
        NSWorkspace.shared.open(item.url)
    }

    func shareSelected() {
        guard let item = selectedItem else { return }
        let picker = NSSharingServicePicker(items: [item.url])
        if let view = NSApp.keyWindow?.contentView {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }

    private func buildTree(url: URL, depth: Int) -> [FileItem] {
        guard depth < 4 else { return [] }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { child in
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return FileItem(
                    id: UUID(),
                    url: child,
                    children: isDir ? buildTree(url: child, depth: depth + 1) : nil
                )
            }
    }
}
