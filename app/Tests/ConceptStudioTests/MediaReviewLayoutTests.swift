import AppKit
@testable import ConceptStudio
import SwiftUI
import Testing

@Suite("crop preview geometry")
struct CropPreviewGeometryTests {
    @Test func landscapeCropUsesImageBoundsRatherThanLetterbox() {
        let geometry = CropPreviewGeometry(
            imageSize: CGSize(width: 400, height: 200), availableSize: CGSize(width: 300, height: 300),
            crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )
        #expect(geometry.imageRect == CGRect(x: 0, y: 75, width: 300, height: 150))
        #expect(geometry.cropRect == CGRect(x: 75, y: 112.5, width: 150, height: 75))
    }

    @Test func portraitCropUsesTopLeftCoordinatesInsideFittedImage() {
        let geometry = CropPreviewGeometry(
            imageSize: CGSize(width: 200, height: 400), availableSize: CGSize(width: 600, height: 300),
            crop: CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
        )
        #expect(geometry.imageRect == CGRect(x: 225, y: 0, width: 150, height: 300))
        #expect(geometry.cropRect == CGRect(x: 255, y: 90, width: 90, height: 120))
    }

    @Test func dimmingCoversAllFourExcludedEdgesButNotKeptPixelsOrLetterbox() {
        let geometry = CropPreviewGeometry(
            imageSize: CGSize(width: 400, height: 200), availableSize: CGSize(width: 300, height: 300),
            crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )
        let mask = geometry.excludedPixels
        for point in [
            CGPoint(x: 25, y: 150),
            CGPoint(x: 275, y: 150),
            CGPoint(x: 150, y: 90),
            CGPoint(x: 150, y: 210),
        ] {
            #expect(mask.contains(point, eoFill: true))
        }
        #expect(!mask.contains(CGPoint(x: 150, y: 150), eoFill: true))
        #expect(!mask.contains(CGPoint(x: 150, y: 25), eoFill: true))
        #expect(!mask.contains(CGPoint(x: 150, y: 275), eoFill: true))
    }

    @Test func wholeImageKeepsAllFourEdgesAndDimsNoImagePixels() {
        let geometry = CropPreviewGeometry(
            imageSize: CGSize(width: 200, height: 400), availableSize: CGSize(width: 600, height: 300),
            crop: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        #expect(geometry.cropRect == geometry.imageRect)
        #expect(!geometry.excludedPixels.contains(CGPoint(x: 300, y: 150), eoFill: true))
    }

    @Test func previewFractionsMatchActualApprovedCrop() throws {
        let image = try MediaFixtures.image(width: 80, height: 60)
        let rectangle = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let approved = try MediaEditor.orientedImage(MediaEditor.cropped(MediaEditor.png(image), rectangle: rectangle))
        let geometry = CropPreviewGeometry(
            imageSize: CGSize(width: image.width, height: image.height),
            availableSize: CGSize(width: 648, height: 300), crop: rectangle
        )
        #expect(geometry.cropRect.width / geometry.imageRect.width == CGFloat(approved.width) / CGFloat(image.width))
        #expect(geometry.cropRect.height / geometry.imageRect
            .height == CGFloat(approved.height) / CGFloat(image.height))
    }
}

/// Measure the actual native TextEditor before/after the notice appears, without showing a window.
@Suite("Review layout remains stable while editing", .serialized)
@MainActor
struct ReviewLayoutTests {
    @Test(arguments: [CGFloat(760), CGFloat(1000)])
    func unsavedNoticeDoesNotChangeCaptionColumn(availableWidth: CGFloat) async throws {
        let directory = temporaryTestDirectory("review-layout")
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = try StudioProject.create(at: directory)
        let url = project.imagesDirectory.appendingPathComponent("sample.png")
        try MediaEditor.png(MediaFixtures.image()).write(to: url)
        let image = ProjectImage(url: url, caption: "NORA7 beside a window.")
        project.images = [image]
        let suite = "ConceptStudio.review-layout." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = StudioSession(preferences: preferences)
        session.project = project
        session.selectedImageID = image.id
        session.reviewSelection = [image.id]
        _ = NSApplication.shared
        let size = CGSize(width: availableWidth, height: 600)
        let host = NSHostingView(rootView: ReviewView(session: session).frame(width: size.width, height: size.height))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        defer { window.contentView = nil; window.close() }
        let before = try await editorFrame(in: host)
        if availableWidth == 1000 { #expect(before.minX > 400) }
        session.setCaptionDraft(CaptionDraft(text: image.caption + " Edited caption.", isFinal: false), for: image.id)
        let edited = try await editorFrame(in: host)
        #expect(abs(edited.minX - before.minX) < 1)
        #expect(abs(edited.width - before.width) < 1)
        session.discardCaptionDraft(for: image)
        let discarded = try await editorFrame(in: host)
        #expect(abs(discarded.minX - before.minX) < 1)
        #expect(!window.isVisible)
    }

    private func editorFrame(in host: NSView) async throws -> CGRect {
        // Allow SwiftUI's observation/layout update to settle; never read an unchanged pending layout.
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        let editor = try #require(textEditor(in: host))
        let container: NSView = editor.enclosingScrollView ?? editor
        return container.convert(container.bounds, to: host)
    }

    private func textEditor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap { textEditor(in: $0) }.first
    }
}
