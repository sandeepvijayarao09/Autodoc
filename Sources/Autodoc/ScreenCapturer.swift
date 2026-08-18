import Foundation
import ScreenCaptureKit
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A single captured frame plus attribution metadata. `png` is Sendable Data so
/// the CGImage never has to cross an actor boundary. `heic` is the small,
/// storage-friendly encoding, produced only when frames are being kept.
struct Frame: Sendable {
    var png: Data
    var heic: Data?
    var appName: String?
    var windowTitle: String?
    var aHash: UInt64
}

enum CaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case noDisplay
    case encodeFailed
    var description: String {
        switch self {
        case .permissionDenied: return "Screen Recording permission denied"
        case .noDisplay: return "no display available"
        case .encodeFailed: return "failed to encode frame"
        }
    }
}

/// Wraps ScreenCaptureKit: Apple's supported path for screen capture, with
/// explicit permission signalling and per-app exclusion (unlike the CLI tool).
enum ScreenCapturer {

    /// True if the app currently holds Screen Recording permission.
    static func hasPermission() async -> Bool {
        do { _ = try await SCShareableContent.current; return true }
        catch { return false }
    }

    static func capture(excludingBundleIDs excluded: Set<String>,
                        maxDimension: Int, keepFrame: Bool = false) async throws -> Frame {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }
        let front = NSWorkspace.shared.frontmostApplication
        guard let display = activeDisplay(in: content, frontmost: front) else {
            throw CaptureError.noDisplay
        }

        let excludedApps = content.applications.filter { excluded.contains($0.bundleIdentifier) }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: excludedApps,
                                     exceptingWindows: [])

        let config = SCStreamConfiguration()
        let longest = max(display.width, display.height)
        let scale = longest > maxDimension ? Double(maxDimension) / Double(longest) : 1.0
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)

        guard let png = pngData(from: cgImage) else { throw CaptureError.encodeFailed }
        let heic = keepFrame ? heicData(from: cgImage, quality: 0.6) : nil

        // Attribution: frontmost app + its on-screen window title.
        let appName = front?.localizedName
        let title = content.windows.first {
            $0.owningApplication?.bundleIdentifier == front?.bundleIdentifier && $0.isOnScreen
        }?.title

        return Frame(png: png, heic: heic, appName: appName, windowTitle: title,
                     aHash: averageHash(cgImage))
    }

    /// Encode a CGImage as lossy HEIC — ~7× smaller than PNG for screen content.
    static func heicData(from cg: CGImage, quality: Double = 0.6) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Display selection

    /// The display the user is actually working on.
    ///
    /// Capturing `displays.first` (the primary display) silently logs the wrong
    /// screen for anyone working on an external monitor. Preference order:
    /// the display showing the frontmost app's window, then the display under
    /// the mouse, then the primary.
    static func activeDisplay(in content: SCShareableContent,
                              frontmost: NSRunningApplication?) -> SCDisplay? {
        guard !content.displays.isEmpty else { return nil }

        func display(containing point: CGPoint) -> SCDisplay? {
            content.displays.first { $0.frame.contains(point) }
        }

        // 1. Where the frontmost app's on-screen window is.
        if let bundleID = frontmost?.bundleIdentifier,
           let window = content.windows.first(where: {
               $0.owningApplication?.bundleIdentifier == bundleID && $0.isOnScreen
           }) {
            let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
            if let d = display(containing: centre) { return d }
        }

        // 2. Where the pointer is. NSEvent uses a bottom-left origin, while
        //    SCDisplay.frame is top-left, so flip Y against the primary height.
        if let primaryHeight = content.displays.first?.frame.height {
            let mouse = NSEvent.mouseLocation
            let flipped = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
            if let d = display(containing: flipped) { return d }
        }

        // 3. Primary display.
        return content.displays.first
    }

    // MARK: - Helpers

    private static func pngData(from cg: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }

    /// 64-bit average hash for cheap perceptual idle detection.
    static func averageHash(_ cg: CGImage) -> UInt64 {
        let w = 8, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        let space = CGColorSpaceCreateDeviceGray()
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w, space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        let mean = pixels.reduce(0) { $0 + Int($1) } / (w * h)
        var bits: UInt64 = 0
        for (i, p) in pixels.enumerated() where Int(p) >= mean {
            bits |= (UInt64(1) << UInt64(i))
        }
        return bits
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}
