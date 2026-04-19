import Foundation
import SwiftData

enum BackupEngine {

    private static var maxSlots: Int {
        let stored = UserDefaults.standard.integer(forKey: "backupMaxSlots")
        return stored > 0 ? min(stored, 10) : 3
    }

    @MainActor
    static func performBackup(
        container: ModelContainer,
        destination: BackupDestination,
        progress: @MainActor @escaping (_ current: Int, _ total: Int, _ isFinalizing: Bool) -> Void = { _, _, _ in }
    ) async throws {
        let context = ModelContext(container)
        let clipItems = try context.fetch(FetchDescriptor<ClipItem>())
        let groups = (try? context.fetch(FetchDescriptor<SmartGroup>())) ?? []
        let rules = (try? context.fetch(FetchDescriptor<AutomationRule>())) ?? []

        // Build ExportItems in batches on the main thread (SwiftData requires it),
        // yielding between batches so the UI stays responsive during large backups.
        let total = clipItems.count
        var exportItems: [ExportItem] = []
        exportItems.reserveCapacity(total)
        let batchSize = 100
        for i in stride(from: 0, to: total, by: batchSize) {
            let end = min(i + batchSize, total)
            for j in i..<end {
                exportItems.append(DataPorter.buildSingleExportItem(clipItems[j]))
            }
            progress(end, total, false)
            await Task.yield()
        }
        // Switch UI to the "finalizing" state: compression + upload run on a
        // background task but can still take a few seconds for large backups.
        progress(total, total, true)
        // Groups / rules are tiny, map in one shot.
        let exportGroups = groups.map(DataPorter.buildSingleExportGroup)
        let exportRules = rules.map(DataPorter.buildSingleExportRule)

        let payload = ExportPayload(
            version: DataPorter.currentVersion,
            exportDate: Date(),
            items: exportItems,
            groups: exportGroups,
            rules: exportRules
        )

        // Encode + zlib compression are CPU-heavy for thousands of items (especially with
        // base64-encoded images) — run them off the main actor.
        let fileData = try await Task.detached(priority: .userInitiated) {
            let jsonData = try DataPorter.encodeAndCompress(payload)
            return DataPorterCrypto.wrapPlaintext(jsonData)
        }.value

        let currentSlot = UserDefaults.standard.integer(forKey: "backupCurrentSlot")
        let nextSlot = (currentSlot % maxSlots) + 1

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let fileName = "PasteMemo-backup-\(nextSlot)-\(timestamp)-\(clipItems.count)items.pastememo"

        let slots = maxSlots
        let existingBackups = try await destination.list()

        // Delete the file occupying the next slot
        if let oldFile = existingBackups.first(where: { $0.slot == nextSlot }) {
            try await destination.delete(fileName: oldFile.fileName)
        }

        // Clean up files with slot numbers exceeding current maxSlots
        for stale in existingBackups where stale.slot > slots {
            try await destination.delete(fileName: stale.fileName)
        }

        try await destination.upload(data: fileData, fileName: fileName)

        UserDefaults.standard.set(nextSlot, forKey: "backupCurrentSlot")
        UserDefaults.standard.set(Date(), forKey: "backupLastDate")
    }

    static func listBackups(
        destination: BackupDestination
    ) async throws -> [BackupMetadata] {
        try await destination.list()
    }

    @MainActor
    static func restore(
        from backup: BackupMetadata,
        destination: BackupDestination,
        strategy: RestoreStrategy,
        container: ModelContainer
    ) async throws -> RestoreResult {
        let fileData = try await destination.download(fileName: backup.fileName)

        let jsonData: Data
        do {
            jsonData = try DataPorterCrypto.decrypt(fileData: fileData, password: "")
        } catch {
            throw BackupError.invalidBackupFile
        }

        let context = ModelContext(container)

        if strategy == .overwrite {
            // Wipe clips and groups entirely; keep built-in rules (owned by BuiltInRules),
            // wipe user-defined ones.
            for item in (try? context.fetch(FetchDescriptor<ClipItem>())) ?? [] {
                context.delete(item)
            }
            for group in (try? context.fetch(FetchDescriptor<SmartGroup>())) ?? [] {
                context.delete(group)
            }
            let userRules = (try? context.fetch(
                FetchDescriptor<AutomationRule>(predicate: #Predicate { !$0.isBuiltIn })
            )) ?? []
            for rule in userRules {
                context.delete(rule)
            }
        }

        let result = try DataPorter.importItems(from: jsonData, into: context)
        return RestoreResult(restoredCount: result.imported, skippedCount: result.skipped)
    }
}
