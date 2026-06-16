import AppKit
import FilterCore
import ScreenCaptureKit
import Vision

/// Whole-display OCR. Captures each screen in full and reads all visible text
/// with Vision, independent of which window is frontmost or how windows are
/// stacked. Runs automatically as the always-on coverage layer for anything
/// the Accessibility tree can't expose (PDF viewers, images of text, canvas-
/// rendered apps). Everything is processed in memory on-device.
struct OCRTextSource {

    enum OCRError: LocalizedError {
        case captureFailed
        var errorDescription: String? {
            "Screen capture failed — allow Screen Recording in System Settings → Privacy & Security."
        }
    }

    /// Capture and OCR every active display. Our own overlay panels are
    /// excluded from the capture so highlighted regions can't feed themselves.
    func acquireWholeScreen(excludingPID ownPID: pid_t) async throws -> [AcquiredBlock] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { return [] }

        let ourWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        var blocks: [AcquiredBlock] = []

        for display in content.displays {
            let scale = 2.0
            let configuration = SCStreamConfiguration()
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.showsCursor = false
            configuration.captureResolution = .best

            let filter = SCContentFilter(display: display, excludingWindows: ourWindows)
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration) else {
                throw OCRError.captureFailed
            }

            let lines = try recognizeLines(in: image)
            let clustered = BlockClustering.cluster(
                lines.map { BlockClustering.Item(text: $0.text, rect: $0.rect) },
                minChars: 120
            )

            // Image pixels → that display's global CG frame → Cocoa screen space.
            let displayFrame = display.frame
            let sx = displayFrame.width / CGFloat(image.width)
            let sy = displayFrame.height / CGFloat(image.height)

            for block in clustered {
                let global = CGRect(
                    x: displayFrame.minX + block.rect.minX * sx,
                    y: displayFrame.minY + block.rect.minY * sy,
                    width: block.rect.width * sx,
                    height: block.rect.height * sy
                )
                blocks.append(AcquiredBlock(text: block.text, screenRect: global.axToCocoa, source: .ocr))
            }
        }
        return blocks
    }

    private struct Line {
        let text: String
        let rect: CGRect // image pixels, top-left origin
    }

    private func recognizeLines(in image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])

        let height = CGFloat(image.height)
        let width = CGFloat(image.width)

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision: normalized, bottom-left origin → pixels, top-left origin.
            let bounds = observation.boundingBox
            let rect = CGRect(
                x: bounds.minX * width,
                y: (1 - bounds.maxY) * height,
                width: bounds.width * width,
                height: bounds.height * height
            )
            return Line(text: candidate.string, rect: rect)
        }
    }
}
