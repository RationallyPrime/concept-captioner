import AVKit
import ConceptCore
import SwiftUI

struct MediaEditorView: View {
    @Bindable var session: StudioSession
    let media: ProjectImage
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var rectangle = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var info: VideoInfo?
    @State private var frames: [MediaFrame] = []
    @State private var player: AVPlayer?
    @State private var timeline: VideoTimeline?
    @State private var format: VideoTrainingFormat
    @State private var startFrame = 0
    @State private var frameCount = 33
    @State private var longEdge = 512
    @State private var fittedSize: CGSize?
    @State private var previewLongEdge: Int?
    @State private var error = ""
    @State private var confirmReset = false

    init(session: StudioSession, media: ProjectImage) {
        self.session = session
        self.media = media
        _format = State(initialValue: VideoTrainingFormat(profile: session.project?.job.profile ?? "ltx-video"))
    }

    private var isVideo: Bool {
        Sources.isVideo(Sources.suffix(of: media.id))
    }

    private var hasCaptionToReset: Bool {
        !media.caption.isEmpty || session.hasUnsavedCaption(for: media)
    }

    private var selectedRange: CMTimeRange? {
        timeline?.range(startFrame: startFrame, frameCount: frameCount, format: format)
    }

    private var constantRateSelection: Bool {
        timeline?.supportsTiming(startFrame: startFrame, frameCount: frameCount, format: format) == true
    }

    private var maximumStartFrame: Int {
        guard let timeline, format.accepts(frameCount: frameCount),
              frameCount <= timeline.maximumTrainingFrames(format: format) else { return 0 }
        return timeline.times.count - frameCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isVideo ? "Inspect and select a training segment" : "Approve a training crop").font(.title2.bold())
            Text(media.id).foregroundStyle(StudioStyle.supportingText).lineLimit(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StudioTermsHelp(terms: isVideo ? [.trainingData, .fps, .resolution, .captionFormat]
                        : [.trainingData, .resolution, .mapping])
                    if isVideo { videoControls } else { cropControls }
                    if hasCaptionToReset {
                        Text(
                            "Changing the training target resets its mapping and caption, "
                                + "including a protected final caption. "
                                + "Unsaved caption edits are discarded. "
                                + "Undo restores the previous target and saved caption."
                        )
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                    }
                    if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isVideo ? "Approve segment" : "Approve crop") {
                    if hasCaptionToReset { confirmReset = true } else { approve() }
                }.buttonStyle(.borderedProminent).tint(StudioStyle.actionTint)
                    .disabled(session.busy || session.editing || (isVideo ?
                            selectedRange == nil || !constantRateSelection || previewLongEdge != longEdge : image ==
                            nil))
            }
        }.padding(24).frame(width: 720, height: 660)
            .task {
                do {
                    if isVideo {
                        let details = try await MediaEditor.videoInfo(url: media.url)
                        info = details
                        let decoded = try await MediaEditor.videoTimeline(url: media.url)
                        timeline = decoded
                        frameCount = format.initialSelectionFrames(available: decoded.times.count)
                        frames = try await MediaEditor.frames(url: media.url)
                    } else {
                        image = try await Task.detached {
                            try MediaEditor.orientedImage(Data(contentsOf: media.url))
                        }.value
                    }
                } catch { self.error = error.localizedDescription }
            }
            .task(id: longEdge) {
                guard isVideo else { return }
                do {
                    let composition = try await MediaEditor.fittedVideoComposition(url: media.url, longEdge: longEdge)
                    try Task.checkCancellation()
                    let item = AVPlayerItem(url: media.url)
                    item.videoComposition = composition
                    player?.pause()
                    player = AVPlayer(playerItem: item)
                    fittedSize = composition.renderSize
                    previewLongEdge = longEdge
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
            .onDisappear { player?.pause(); player?.replaceCurrentItem(with: nil); player = nil }
            .onChange(of: format) { _, selected in
                guard let timeline else { return }
                frameCount = selected.initialSelectionFrames(available: timeline.times.count)
                startFrame = min(max(0, startFrame), maximumStartFrame)
            }
            .confirmationDialog("Replace this training target and reset its caption?", isPresented: $confirmReset) {
                Button(isVideo ? "Approve segment and reset caption" : "Approve crop and reset caption") { approve() }
                Button("Keep current target", role: .cancel) {}
            }
    }

    @ViewBuilder private var cropControls: some View {
        if let image {
            GeometryReader { geometry in
                let crop = CropPreviewGeometry(
                    imageSize: CGSize(width: image.width, height: image.height),
                    availableSize: geometry.size, crop: rectangle
                )
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1).resizable()
                        .frame(width: crop.imageRect.width, height: crop.imageRect.height)
                        .position(x: crop.imageRect.midX, y: crop.imageRect.midY)
                    crop.excludedPixels.fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                    Rectangle().strokeBorder(.black, lineWidth: 4)
                        .overlay { Rectangle().strokeBorder(.orange, lineWidth: 2) }
                        .frame(width: crop.cropRect.width, height: crop.cropRect.height)
                        .position(x: crop.cropRect.midX, y: crop.cropRect.midY)
                }
                .allowsHitTesting(false)
            }.frame(height: 300)
            HStack {
                Button("Whole image") { rectangle = CGRect(x: 0, y: 0, width: 1, height: 1) }
                if let face = session.analyses[media.id]?.faces.first {
                    Button("Suggest face-centered crop") { rectangle = MediaEditor.suggestedCrop(face: face) }
                }
            }
            cropSlider("Left", keyPath: \.origin.x, range: 0 ... 0.95)
            cropSlider("Top", keyPath: \.origin.y, range: 0 ... 0.95)
            cropSlider("Width", keyPath: \.size.width, range: 0.05 ... (1 - rectangle.minX))
            cropSlider("Height", keyPath: \.size.height, range: 0.05 ... (1 - rectangle.minY))
            Text("Only the approved crop will be captioned and sent to the trainer.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
        } else { ProgressView("Loading image…") }
    }

    private func cropSlider(
        _ label: String,
        keyPath: WritableKeyPath<CGRect, CGFloat>,
        range: ClosedRange<CGFloat>
    ) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: Binding(get: { rectangle[keyPath: keyPath] }, set: {
                rectangle[keyPath: keyPath] = $0
                rectangle.size.width = min(rectangle.width, 1 - rectangle.minX)
                rectangle.size.height = min(rectangle.height, 1 - rectangle.minY)
            }), in: range).accessibilityLabel(label + " crop fraction")
            Text(rectangle[keyPath: keyPath], format: .percent.precision(.fractionLength(0))).monospacedDigit()
                .frame(width: 50)
        }
    }

    @ViewBuilder private var videoControls: some View {
        if let info {
            Picker("Training model", selection: $format) {
                ForEach(VideoTrainingFormat.allCases) { Text($0.title).tag($0) }
            }
            .help("Choose the diffusion model that will learn this segment; its supported durations differ.")
            Text(format == .h3
                ? "H3 requires 24 frames per second and specific segment lengths. Approval keeps those exact frames."
                : "LTX supports specific segment lengths. Approval keeps the selected frames at their original timing.")
                .font(.callout).foregroundStyle(StudioStyle.supportingText)
            if session.project?.job.profile != format.rawValue {
                Text("Approving selects \(format.title) video captions for this project. Other existing captions "
                    + "keep their text; review or re-caption them for the new format.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
            }
            if let timeline, timeline.maximumTrainingFrames(format: format) >= format.minimumFrames {
                HStack {
                    Text("Start time")
                    Slider(value: Binding(
                        get: { timeline.times[min(max(0, startFrame), maximumStartFrame)].seconds },
                        set: { startFrame = Self.nearestFrame(
                            to: $0,
                            in: timeline.times,
                            maximumIndex: maximumStartFrame
                        ) }
                    ), in: timeline.times[0].seconds ... max(
                        timeline.times[0].seconds + 0.001, timeline.times[maximumStartFrame].seconds
                    ))
                    .disabled(maximumStartFrame == 0)
                    .accessibilityLabel("Start time, snapped to an actual video frame")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: adjustStartFrame(by: 1)
                        case .decrement: adjustStartFrame(by: -1)
                        @unknown default: break
                        }
                    }
                    .onKeyPress(.leftArrow) { adjustStartFrame(by: -1); return .handled }
                    .onKeyPress(.rightArrow) { adjustStartFrame(by: 1); return .handled }
                    Text(
                        timeline.times[min(max(0, startFrame), maximumStartFrame)].seconds,
                        format: .number.precision(.fractionLength(3))
                    )
                    .monospacedDigit()
                    Text("seconds")
                }
                Picker("Duration", selection: Binding(get: { frameCount }, set: { count in
                    frameCount = count
                    startFrame = min(max(0, startFrame), timeline.times.count - count)
                })) {
                    ForEach(
                        Self.durationChoices(
                            in: timeline, startFrame: startFrame, currentCount: frameCount, format: format
                        ),
                        id: \.self
                    ) { count in
                        if let range = timeline.range(startFrame: startFrame, frameCount: count, format: format) {
                            Text("\(range.duration.seconds.formatted(.number.precision(.fractionLength(3)))) seconds")
                                .tag(count)
                        }
                    }
                }
                Text("A video frame is one still image. \(format.title) supports specific segment lengths; "
                    + "choose the duration closest to what you need.")
                    .font(.callout).foregroundStyle(StudioStyle.supportingText)
                if let range = selectedRange {
                    let start = range.start.seconds.formatted(.number.precision(.fractionLength(3)))
                    let end = range.end.seconds.formatted(.number.precision(.fractionLength(3)))
                    Text("Selected: \(start)–\(end) seconds")
                        .monospacedDigit().font(.callout)
                    if !constantRateSelection {
                        Text(format == .h3
                            ? "This segment does not have constant timing at 24 frames per second. "
                            + "Choose a compatible portion or import a 24 fps copy; approval never retimes it."
                            : "This segment has variable frame timing that LTX cannot preserve. "
                            + "Choose a constant-rate portion or import a constant-frame-rate copy.")
                            .foregroundStyle(.orange)
                    }
                    Button("Preview selected segment") {
                        guard let player else { return }
                        player.currentItem?.forwardPlaybackEndTime = range.end
                        player.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                            if finished { player.play() }
                        }
                    }
                } else {
                    Text("Choose an available start frame and a length of \(format.gridDescription) frames, "
                        + "from \(format.minimumFrames) through "
                        + "\(format.maximumFrames(available: MediaEditor.maximumVideoFrames)).")
                        .foregroundStyle(.orange)
                }
            } else if timeline != nil {
                Text("This clip has fewer than \(format.minimumFrames) frames. "
                    + "Choose a longer clip for \(format.title) video training.")
                    .foregroundStyle(.orange)
            } else if error.isEmpty {
                ProgressView("Counting actual decoded frames…")
            }
            VideoPlayer(player: player).frame(height: 180)
            Text(
                "\(info.width) × \(info.height) · "
                    + "\(info.duration.formatted(.number.precision(.fractionLength(2)))) seconds · "
                    + (info.hasAudio ? "audio track present" : "no audio track")
            )
            .font(.callout).foregroundStyle(StudioStyle.supportingText)
            DisclosureGroup("Advanced: Exact frames and size") {
                if let timeline, timeline.maximumTrainingFrames(format: format) >= format.minimumFrames {
                    HStack {
                        Text("Start frame (from zero)")
                        TextField("Start frame", value: $startFrame, format: .number).frame(width: 70)
                        Stepper("Start frame", value: $startFrame, in: 0 ... maximumStartFrame).labelsHidden()
                        Text("Length (frames)")
                        TextField("Frame count", value: $frameCount, format: .number).frame(width: 70)
                        Stepper(
                            "Frame count", value: $frameCount,
                            in: format.minimumFrames ... timeline.maximumTrainingFrames(format: format),
                            step: format.frameStep
                        )
                        .labelsHidden()
                    }
                }
                Picker("Maximum width or height", selection: $longEdge) {
                    ForEach(GPUWorkspace.resolutionChoices, id: \.self) { pixels in
                        Text("\(pixels) pixels").tag(pixels)
                    }
                }
                if let fittedSize {
                    Text("Approved canvas: \(Int(fittedSize.width)) × \(Int(fittedSize.height)). "
                        + "The full oriented frame is fitted without cropping; "
                        + "small borders align its size to 32 pixels.")
                        .font(.callout).foregroundStyle(StudioStyle.supportingText)
                }
            }
            Text("Inspect frames over time").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(frames) { frame in
                        VStack {
                            Image(decorative: frame.image, scale: 1).resizable().scaledToFit()
                                .frame(width: 96, height: 66)
                            Button("\(frame.seconds.formatted(.number.precision(.fractionLength(2)))) s") {
                                player?.pause()
                                player?.currentItem?.forwardPlaybackEndTime = .invalid
                                player?.seek(
                                    to: CMTime(seconds: frame.seconds, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero
                                )
                            }.accessibilityLabel("Seek to \(frame.seconds) seconds")
                        }
                    }
                }
            }
            Text(
                "Approval exports and recounts exactly the chosen frames at their original timing. "
                    + "The training model must use these approved frames and dimensions. "
                    + "No frames or edges are silently removed. "
                    + "Caption timestamps begin at zero in the approved segment. "
                    + "Use a video-capable Gemini, OpenRouter or vLLM model for captioning; "
                    + "unsupported providers give an explicit error."
            )
            .font(.callout).foregroundStyle(StudioStyle.supportingText)
        } else { ProgressView("Reading clip…") }
    }

    /// Choose the nearest permitted decoded timestamp; moving the slider never invents a frame.
    static func nearestFrame(to seconds: Double, in times: [CMTime], maximumIndex: Int) -> Int {
        guard seconds.isFinite, !times.isEmpty else { return 0 }
        let maximum = min(max(0, maximumIndex), times.count - 1)
        var lower = 0, upper = maximum
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if times[middle].seconds < seconds { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return lower }
        return abs(times[lower - 1].seconds - seconds) <= abs(times[lower].seconds - seconds) ? lower - 1 : lower
    }

    static func durationChoices(
        in timeline: VideoTimeline, startFrame: Int, currentCount: Int, format: VideoTrainingFormat = .ltx
    ) -> [Int] {
        let counts = format == .ltx ? [9, 17, 33, 49, 97, 129, 257] : Array(stride(
            from: format.minimumFrames, through: timeline.maximumTrainingFrames(format: format), by: format.frameStep
        ))
        return Set(counts + [currentCount])
            .filter { timeline.range(startFrame: startFrame, frameCount: $0, format: format) != nil }.sorted()
    }

    private func adjustStartFrame(by direction: Int) {
        let current = min(max(0, startFrame), maximumStartFrame)
        startFrame = min(max(0, current + direction), maximumStartFrame)
    }

    private func approve() {
        if isVideo {
            session.approveVideoSegment(
                id: media.id,
                startFrame: startFrame,
                frameCount: frameCount,
                longEdge: longEdge,
                format: format
            )
        } else {
            session.approveCrop(id: media.id, rectangle: rectangle)
        }
        dismiss()
    }
}
