import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit

/// Captures per-Space screenshots using ScreenCaptureKit.
///
/// **Permission**: requires the Screen Recording TCC entry. Off by default
/// — gated by `MenuBarStatusModel.enableSpaceScreenshots`, which itself
/// requires an explicit consent dialog before the user can flip on.
///
/// **Single-Space limitation**: like AX, SCK can only capture content
/// that's currently visible. We capture during the Space-switch
/// auto-capture flow (after the 5s dwell), so the active Space is what
/// gets imaged. Other Spaces get imaged when the user visits them next.
///
/// **API note**: uses `SCScreenshotManager.captureImage`, which is the
/// modern (macOS 14+) replacement for the deprecated
/// `CGWindowListCreateImage`. Falls back to nil on any failure rather
/// than throwing — a missing thumbnail is a UX downgrade, not a
/// correctness problem.
public enum ScreenshotCapturer {

    /// Returns `true` if Screen Recording permission is currently granted.
    /// Doesn't prompt — purely a check. Use `requestPermission` to prompt.
    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the Screen Recording permission prompt. The system shows
    /// the prompt **only on the first call per app code identity** — after
    /// that, denied apps must be granted via System Settings → Privacy &
    /// Security → Screen Recording. Caller should inspect `hasPermission()`
    /// shortly after to know the result.
    @discardableResult
    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Capture the primary display as JPEG. Returns nil on permission
    /// denial, capture failure, or encoding failure. Logs to DiagnosticLog
    /// in every failure path so debugging doesn't require Console.app.
    ///
    /// - Parameter maxWidth: longest-side downscale target (pixels). 800 is
    ///   plenty for a Scenes-picker thumbnail and keeps file size in the
    ///   ~150-400 KB range at quality 0.7.
    public static func captureActiveDisplay(maxWidth: CGFloat = 800) async -> Data? {
        guard hasPermission() else {
            DiagnosticLog.write("screenshot", "skip: Screen Recording permission not granted")
            return nil
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                DiagnosticLog.write("screenshot", "skip: no shareable displays")
                return nil
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // Capture at native resolution; we downscale at encode time so
            // the source quality is good even after compression.
            config.width = Int(display.width) * 2     // assume Retina; SCK accepts pixel dimensions
            config.height = Int(display.height) * 2
            config.showsCursor = false
            config.scalesToFit = true

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )

            // Downscale + JPEG-encode.
            return encodeJPEG(cgImage, maxWidth: maxWidth, quality: 0.7)
        } catch {
            DiagnosticLog.write("screenshot", "capture failed: \(error)")
            return nil
        }
    }

    // MARK: - Encoding

    private static func encodeJPEG(_ image: CGImage, maxWidth: CGFloat, quality: CGFloat) -> Data? {
        let srcW = CGFloat(image.width)
        let srcH = CGFloat(image.height)
        let scale = min(1.0, maxWidth / srcW)
        let targetW = Int(srcW * scale)
        let targetH = Int(srcH * scale)

        let scaled: CGImage
        if scale < 1.0 {
            scaled = redraw(image, to: CGSize(width: targetW, height: targetH)) ?? image
        } else {
            scaled = image
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            DiagnosticLog.write("screenshot", "encode failed: CGImageDestinationCreate returned nil")
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, scaled, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            DiagnosticLog.write("screenshot", "encode failed: Finalize returned false")
            return nil
        }
        return data as Data
    }

    private static func redraw(_ image: CGImage, to size: CGSize) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }
}
