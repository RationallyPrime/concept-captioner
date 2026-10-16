import AVKit
import ConceptCore
import SwiftUI

/// Detail inspection uses the actual selected clip; gallery thumbnails remain still previews.
struct TrainingTargetPreview: View {
    let url: URL
    var faces: [CGRect] = []
    var fill = false
    @State private var player: AVPlayer?

    var body: some View {
        if Sources.isVideo(Sources.suffix(of: url.lastPathComponent)) {
            VideoPlayer(player: player)
                .accessibilityLabel("Selected training clip: " + url.lastPathComponent)
                .task(id: url) {
                    player?.pause()
                    player = AVPlayer(url: url)
                }
                .onDisappear {
                    player?.pause()
                    player?.replaceCurrentItem(with: nil)
                    player = nil
                }
        } else {
            PhotoView(url: url, faces: faces, fill: fill)
        }
    }
}
