import SwiftUI
import WebKit

struct TensorBoardView: View {
    let url: URL
    let token: String
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var reloadID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if loading { ProgressView("Connecting to TensorBoard…").controlSize(.small) }
                Spacer()
                Button("Reload TensorBoard", systemImage: "arrow.clockwise") {
                    errorMessage = nil
                    loading = true
                    reloadID = UUID()
                }
            }
            if let errorMessage {
                StudioNotice(
                    "TensorBoard could not load. Check that training has started, then reload. \(errorMessage)",
                    symbol: "exclamationmark.triangle"
                )
            }
            TensorBoardWebView(url: url, token: token, loading: $loading, errorMessage: $errorMessage)
                .id(reloadID)
                .frame(minHeight: 300)
                .accessibilityLabel("TensorBoard training charts")
        }
    }
}

private struct TensorBoardWebView: NSViewRepresentable {
    let url: URL
    let token: String
    @Binding var loading: Bool
    @Binding var errorMessage: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        view.load(request)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.navigationDelegate = nil
        nsView.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: TensorBoardWebView

        init(parent: TensorBoardWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
            parent.errorMessage = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse
        ) async -> WKNavigationResponsePolicy {
            if navigationResponse.isForMainFrame,
               let response = navigationResponse.response as? HTTPURLResponse,
               response.statusCode >= 400 {
                parent.loading = false
                parent.errorMessage = "The training computer returned an error (\(response.statusCode))."
                return .cancel
            } else {
                return .allow
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            fail(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            fail(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.loading = false
            parent.errorMessage = "The chart viewer stopped responding."
        }

        private func fail(_ error: any Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            parent.loading = false
            parent.errorMessage = error.localizedDescription
        }
    }
}
