import Foundation

struct RelayItem: Identifiable {
    let id: UUID
    var content: String
    var imageData: Data?
    var contentKind: ContentKind
    var state: ItemState

    enum ContentKind {
        case text
        case image
        case file
    }

    enum ItemState {
        case pending, current, done, skipped
    }

    var isImage: Bool { contentKind == .image }
    var isFile: Bool { contentKind == .file }

    /// For file items, show filename(s); for others, show content
    var displayName: String {
        guard isFile else { return content }
        let paths = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        if paths.count == 1 {
            return URL(fileURLWithPath: paths[0]).lastPathComponent
        }
        let first = URL(fileURLWithPath: paths[0]).lastPathComponent
        return "\(first) etc. \(paths.count) files"
    }

    init(content: String, imageData: Data? = nil, contentKind: ContentKind = .text) {
        self.id = UUID()
        self.content = content
        self.imageData = imageData
        self.contentKind = contentKind
        self.state = .pending
    }
}
