import AppKit

private let RELAY_POLL_INTERVAL: Duration = .milliseconds(500)

@MainActor
final class RelayClipboardMonitor {

    private var pollTask: Task<Void, Never>?
    private var lastChangeCount: Int = 0
    private var lastContentKey: String = ""
    var onNewClip: (@MainActor (ClipItem) -> Void)?

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: RELAY_POLL_INTERVAL)
                self?.poll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Call after writing to pasteboard to prevent self-detection.
    func skipNextChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        // Skip copies from PasteMemo itself (e.g. editing in main window)
        if let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           frontApp.contains("pastememo") { return }
        guard let clip = ClipboardManager.shared.captureCurrentClipboard() else { return }
        // Opt-in dedup: skip if user hasn't allowed repeats and content matches previous.
        let allowRepeat = UserDefaults.standard.bool(forKey: "relayAllowRepeatCopy")
        let key = dedupKey(for: clip)
        if !allowRepeat, key == lastContentKey { return }
        lastContentKey = key
        onNewClip?(clip)
    }

    /// Identity fingerprint used for consecutive-duplicate detection. Uses text content
    /// for text-like clips and imageData byte count + prefix for images (avoids hashing
    /// megabytes on every poll).
    private func dedupKey(for clip: ClipItem) -> String {
        if clip.contentType == .image, let data = clip.imageData {
            return "image:\(data.count):\(data.prefix(32).hashValue)"
        }
        return "text:\(clip.content)"
    }
}
