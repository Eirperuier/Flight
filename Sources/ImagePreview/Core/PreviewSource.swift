import CoreGraphics
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The thumbnail an image opens from and closes back into.
@MainActor
public struct PreviewSource {
    /// The view showing the thumbnail; its frame on screen is read when the viewer opens and again when it closes.
    public weak var view: PreviewPlatformView?
    /// The thumbnail's corner radius, which the image grows out of and shrinks back into.
    public var cornerRadius: CGFloat
    /// How the thumbnail draws its image, so the first and last frames match it exactly.
    public var contentMode: PreviewContentMode
    let setHidden: (Bool) -> Void

    /// - Parameters:
    ///   - view: The view showing the thumbnail. It is hidden while the viewer shows its image.
    ///   - cornerRadius: The thumbnail's corner radius.
    ///   - contentMode: How the thumbnail draws its image.
    public init(view: PreviewPlatformView, cornerRadius: CGFloat = 0, contentMode: PreviewContentMode = .fill) {
        self.view = view
        self.cornerRadius = cornerRadius
        self.contentMode = contentMode
        self.setHidden = { [weak view] hidden in view?.isHidden = hidden }
    }

    init(view: PreviewPlatformView, cornerRadius: CGFloat, contentMode: PreviewContentMode, setHidden: @escaping (Bool) -> Void) {
        self.view = view
        self.cornerRadius = cornerRadius
        self.contentMode = contentMode
        self.setHidden = setHidden
    }
}

/// How the viewer looks and moves.
public struct ImagePreviewConfiguration: Sendable {
    /// The backdrop behind the image when it is fully open.
    public var backgroundColor: CGColor = CGColor(gray: 0, alpha: 1)
    /// The gap between neighbouring images while swiping.
    public var pageSpacing: CGFloat = 16
    /// How far an image zooms in, relative to fitting the screen.
    public var maximumZoomScale: CGFloat = 4
    /// The spring that opens and closes the viewer.
    public var transitionSpring: PreviewSpring = .transition
    /// The spring that puts the image back after a drag that did not close it.
    public var restoreSpring: PreviewSpring = .restore
    /// A single tap (a click on the Mac) hides and shows the bars (otherwise it closes the viewer).
    public var tapTogglesAccessories = true

    public init() {}
}

/// What the viewer's page can read and do.
@MainActor @Observable
public final class ImagePreviewContext {
    /// The index of the image on screen.
    public internal(set) var index: Int
    /// How many images there are.
    public internal(set) var count: Int
    /// Whether the bars are showing (a tap toggles them).
    public internal(set) var accessoriesVisible = true
    @ObservationIgnored var onDismiss: () -> Void = {}
    @ObservationIgnored var onSelect: (Int) -> Void = { _ in }

    init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }

    /// Closes the viewer, back into the thumbnail if it is on screen.
    public func dismiss() { onDismiss() }

    /// Shows another image.
    public func select(_ index: Int) { onSelect(index) }
}
