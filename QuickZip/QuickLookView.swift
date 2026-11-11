import SwiftUI
import Quartz

/// An inline Quick Look preview of a file (HLD §9).
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = true
        view.previewItem = url as NSURL
        context.coordinator.url = url
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        view.previewItem = url as NSURL
    }

    // No dismantleNSView: with `autostarts` the view activates when it joins a
    // window and deactivates when it leaves one, and `shouldCloseWithWindow`
    // closes it with the window. SwiftUI detaches the view before dismantling
    // it, so calling `close()` there deactivated it a second time and tripped
    // Quick Look's "must be activated" assertion (SIGABRT on macOS 27).

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var url: URL?
    }
}
