import SwiftUI
import AppKit

/// A thumbnail tile that opens a large preview modal on click. Used by
/// both the Restore Picker (per-snapshot row) and the Diagnostics pane.
///
/// The gallery tile stays compact (configurable height, default 120pt)
/// so the surrounding list isn't overwhelmed, but clicking the tile
/// pops a sheet that fills most of the screen with the full image —
/// finally usable for actually identifying a layout.
public struct ZoomableThumbnail: View {
    let image: NSImage
    let caption: String
    var thumbHeight: CGFloat = 120

    @State private var showingFull: Bool = false

    public init(image: NSImage, caption: String, thumbHeight: CGFloat = 120) {
        self.image = image
        self.caption = caption
        self.thumbHeight = thumbHeight
    }

    public var body: some View {
        Button(action: { showingFull = true }) {
            VStack(spacing: 4) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: thumbHeight)
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Click to enlarge")
        .sheet(isPresented: $showingFull) {
            FullPreviewSheet(image: image, caption: caption) {
                showingFull = false
            }
        }
    }
}

private struct FullPreviewSheet: View {
    let image: NSImage
    let caption: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(caption).font(.headline)
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(16)
                .background(Color.black.opacity(0.3))
        }
        .frame(
            minWidth: 800, idealWidth: 1200, maxWidth: 1600,
            minHeight: 540, idealHeight: 760, maxHeight: 1000
        )
    }
}
