import AppKit
import SwiftUI
import PixlPutCore

/// Visual history picker. Lists all rotated snapshots (newest first) plus
/// the master snapshot (if one exists). Each row shows a small gallery of
/// per-Space thumbnails (when available) so the user can pick the layout
/// they want by sight, not by timestamp guessing.
///
/// Thumbnails only exist for the LATEST snapshot when per-Space screenshots
/// are enabled — historical rotated slots don't have their own thumbnails
/// in v1 (would need per-slot thumbnail rotation, ~18 MB at 10 slots × 6
/// Spaces). Rows without thumbnails show a text summary instead.
public enum RestorePickerWindow {

    public static func makeWindowController(lifecycle: AppLifecycle) -> NSWindowController {
        let view = RestorePickerView(lifecycle: lifecycle)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Restore from history"
        window.setContentSize(NSSize(width: 720, height: 560))
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }
}

private struct RestorePickerView: View {
    let lifecycle: AppLifecycle
    @State private var entries: [SnapshotStore.HistoryEntry] = []
    @State private var hasMaster: Bool = false
    /// Per-slot thumbnails. `thumbnailsBySlot[slot][spaceIndex] = image`.
    /// Slots with no per-slot thumbnails are absent from the dict; the
    /// gallery falls back to text in that case.
    @State private var thumbnailsBySlot: [Int: [Int: NSImage]] = [:]
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    if hasMaster {
                        masterRow
                    }
                    ForEach(entries) { entry in
                        historyRow(entry: entry)
                    }
                    if entries.isEmpty && !hasMaster {
                        Text("No saved snapshots yet. Use **Capture now** or wait for an auto-capture to fire.")
                            .foregroundStyle(.secondary)
                            .padding(40)
                    }
                }
                .padding(16)
            }
            if let msg = statusMessage {
                Text(msg).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
        }
        .onAppear { refresh() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading) {
                Text("Restore from history").font(.title2).bold()
                Text("Pick a saved layout to apply. Newest first.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { refresh() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var masterRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
                Text("Master setup").font(.headline)
                Spacer()
                Button("Restore master") { runMaster() }
                    .buttonStyle(.borderedProminent)
            }
            // Master row reuses slot-0 thumbnails as a stand-in until
            // we capture a dedicated set under <id>.master.space<N>.thumb.jpg.
            if let slot0 = thumbnailsBySlot[0], !slot0.isEmpty {
                thumbnailGallery(slot0)
            }
            Text("Your saved ideal layout. Survives auto-captures and rotation.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func historyRow(entry: SnapshotStore.HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: entry.slot == 0 ? "clock.fill" : "clock")
                    .foregroundStyle(entry.slot == 0 ? .blue : .secondary)
                VStack(alignment: .leading) {
                    Text(entry.slot == 0 ? "Current snapshot" : "\(formattedAgo(entry.capturedAt))")
                        .font(.headline)
                    Text("\(entry.windowCount) windows · \(formattedExact(entry.capturedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if entry.slot == 0 {
                    Button("Apply") { runApply(slot: entry.slot) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Apply") { runApply(slot: entry.slot) }
                        .buttonStyle(.bordered)
                }
                Button("Delete", role: .destructive) { runDelete(slot: entry.slot) }
                    .disabled(entry.slot == 0)
            }
            if let slotThumbs = thumbnailsBySlot[entry.slot], !slotThumbs.isEmpty {
                thumbnailGallery(slotThumbs)
            } else if entry.slot == 0 {
                Text("No thumbnails — turn on per-Space screenshots in Settings → Identity & Apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func thumbnailGallery(_ thumbs: [Int: NSImage]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(thumbs.keys.sorted(), id: \.self) { idx in
                    if let img = thumbs[idx] {
                        ZoomableThumbnail(
                            image: img,
                            caption: "Space \(idx + 1)",
                            thumbHeight: 140
                        )
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func refresh() {
        let configID = lifecycle.displayEnumerator.configurationID()
        entries = lifecycle.snapshotStore.listHistory(forConfigurationID: configID)
        hasMaster = lifecycle.snapshotStore.hasMaster(forConfigurationID: configID)
        loadThumbnails()
    }

    private func runApply(slot: Int) {
        statusMessage = "Applying slot \(slot)…"
        lifecycle.restoreFromSlot(slot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            statusMessage = "Applied snapshot from slot \(slot)."
        }
    }

    private func runMaster() {
        statusMessage = "Applying master setup…"
        lifecycle.restoreMaster()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            statusMessage = "Applied master setup."
        }
    }

    private func runDelete(slot: Int) {
        let configID = lifecycle.displayEnumerator.configurationID()
        lifecycle.snapshotStore.delete(forConfigurationID: configID, slot: slot)
        refresh()
        statusMessage = "Deleted slot \(slot)."
    }

    private func loadThumbnails() {
        // Group all thumbnails on disk by slot. Uses ThumbnailStore's
        // own enumeration so the filename parsing stays in one place.
        let configID = lifecycle.displayEnumerator.configurationID()
        let all = lifecycle.thumbnailStore.listAllThumbnails()
            .filter { $0.configID == configID }
        var bySlot: [Int: [Int: NSImage]] = [:]
        for loc in all {
            guard let img = NSImage(contentsOf: loc.url) else { continue }
            bySlot[loc.slot, default: [:]][loc.spaceIndex] = img
        }
        thumbnailsBySlot = bySlot
    }

    private func formattedAgo(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func formattedExact(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: date)
    }
}
