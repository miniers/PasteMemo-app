import Foundation
import SwiftData

@MainActor
final class OCRTaskCoordinator {
    static let shared = OCRTaskCoordinator()

    private var modelContainer: ModelContainer?
    private var inFlightItemIDs = Set<String>()

    private init() {}

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enableOCRKey) as? Bool ?? true
    }

    var autoProcessEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.autoOCRKey) as? Bool ?? true
    }

    func enqueue(itemID: String) {
        guard isEnabled, autoProcessEnabled else { return }
        enqueueForce(itemID: itemID)
    }

    func retry(itemID: String) {
        guard isEnabled else { return }
        enqueueForce(itemID: itemID)
    }

    func canRetry(item: ClipItem) -> Bool {
        isEnabled && item.contentType == .image && item.imageData != nil
    }

    func scanExistingImages() {
        guard let container = modelContainer else { return }
        let context = container.mainContext
        let descriptor = FetchDescriptor<ClipItem>()
        guard let items = try? context.fetch(descriptor) else { return }
        for item in items where item.contentType == .image && item.imageData != nil {
            if item.resolvedOCRStatus != .done {
                enqueueForce(itemID: item.itemID)
            }
        }
    }

    private func enqueueForce(itemID: String) {
        guard let container = modelContainer else { return }
        guard inFlightItemIDs.insert(itemID).inserted else { return }

        Task {
            defer { Task { @MainActor in self.inFlightItemIDs.remove(itemID) } }
            let context = container.mainContext
            guard let item = Self.fetchItem(id: itemID, context: context) else { return }
            guard item.contentType == .image, let imageData = item.imageData else {
                item.ocrStatus = OCRStatus.skipped.rawValue
                item.ocrErrorMessage = nil
                item.ocrUpdatedAt = Date()
                ClipItemStore.saveAndNotify(context)
                return
            }

            item.ocrStatus = OCRStatus.processing.rawValue
            item.ocrErrorMessage = nil
            ClipItemStore.saveAndNotify(context)

            do {
                let result = try await ImageOCRService.shared.recognizeText(from: imageData)
                await MainActor.run {
                    guard let refreshed = Self.fetchItem(id: itemID, context: context) else { return }
                    refreshed.ocrText = result.text.isEmpty ? nil : result.text
                    refreshed.ocrStatus = result.hasText ? OCRStatus.done.rawValue : OCRStatus.skipped.rawValue
                    refreshed.ocrUpdatedAt = Date()
                    refreshed.ocrErrorMessage = nil
                    if let text = refreshed.ocrText, !text.isEmpty {
                        let existing = refreshed.isSensitive
                        refreshed.isSensitive = existing || SensitiveDetector.isSensitive(
                            content: text,
                            sourceAppBundleID: refreshed.sourceAppBundleID,
                            contentType: .text
                        )
                    }
                    ClipItemStore.saveAndNotify(context)
                }
            } catch {
                await MainActor.run {
                    guard let refreshed = Self.fetchItem(id: itemID, context: context) else { return }
                    refreshed.ocrStatus = OCRStatus.failed.rawValue
                    refreshed.ocrUpdatedAt = Date()
                    refreshed.ocrErrorMessage = error.localizedDescription
                    ClipItemStore.saveAndNotify(context)
                }
            }
        }
    }

    private static func fetchItem(id: String, context: ModelContext) -> ClipItem? {
        let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.itemID == id })
        return try? context.fetch(descriptor).first
    }

    static let enableOCRKey = "ocrEnabled"
    static let autoOCRKey = "ocrAutoProcessImages"
}
