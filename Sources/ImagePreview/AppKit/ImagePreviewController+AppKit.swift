#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Shows images over a window, opening out of the thumbnail that was clicked and closing back into it.
///
/// While the images cover the window, its title bar is the viewer's, in the window's own style: a
/// ``title``, the close button and your ``actionsView`` on the toolbar if the window has one, at the end
/// of its compact title bar if not (or, from SwiftUI, a page with a `.navigationTitle`).
///
/// Swipe sideways with two fingers (or drag sideways) to move between images, pinch or
/// double-click to zoom, and swipe or drag an image up or down to close it: it follows,
/// shrinks, and lets the window show through; let go and it flies back into its thumbnail,
/// or springs back. Esc and Space close, the arrow keys move between images.
///
/// ```swift
/// let preview = ImagePreviewController(count: photos.count, index: clicked) { i in
///     PreviewImage(url: photos[i].url, placeholder: thumbnails[i])
/// } source: { i in
///     PreviewSource(view: cells[i].imageView, cornerRadius: 8)
/// }
/// preview.present(from: view)
/// ```
@MainActor
public final class ImagePreviewController {
    public let context: ImagePreviewContext
    public var configuration: ImagePreviewConfiguration
    public var onIndexChange: ((Int) -> Void)?
    public var onDismiss: (() -> Void)?
    public var onDidDismiss: (() -> Void)?
    /// The window's title while the images cover it.
    public var title: String?
    /// Buttons for the image on screen (share, delete), beside the close button: on the window's toolbar
    /// if it has one, at the end of its title bar if not. A click on an image hides and shows them.
    public var actionsView: NSView?

    /// A page that shows the stage inside other content (a SwiftUI hosting view), set before presenting.
    var pageView: NSView?
    /// Makes a view that puts the page's title (and with `true`, its toolbar) on the window while it is in it (a SwiftUI page).
    var makeTitlebar: ((Bool) -> NSView)?
    /// Makes the actions and close button for a title bar without a toolbar (a SwiftUI page).
    var makeTitlebarControls: (() -> NSView)?
    private var titlebarView: NSView?
    private var titlebarControls: NSTitlebarAccessoryViewController?
    public var index: Int { context.index }
    public private(set) var isPresented = false
    var isClosing: Bool { phase == .closing || phase == .closed }

    private let count: Int
    private let contentProvider: (Int) -> any PreviewContent
    private let sourceProvider: (Int) -> PreviewSource?

    public init<Media: PreviewMediaConvertible>(
        count: Int,
        index: Int = 0,
        configuration: ImagePreviewConfiguration = .init(),
        image: @escaping (Int) -> Media,
        source: @escaping (Int) -> PreviewSource? = { _ in nil }
    ) {
        self.count = max(count, 0)
        self.context = ImagePreviewContext(index: min(max(index, 0), max(count - 1, 0)), count: max(count, 0))
        self.configuration = configuration
        self.contentProvider = { image($0).previewMedia.makeContent() }
        self.sourceProvider = source
        context.onDismiss = { [weak self] in self?.dismiss() }
        context.onSelect = { [weak self] in self?.select($0, animated: true) }
    }

    // MARK: Presenting

    /// Opens the viewer over the window `view` is in.
    public func present(from view: NSView) {
        // Above the content view, beside it and below the title bar: a SwiftUI hosting view does
        // not draw views added into it, and this way the backdrop covers the whole window.
        guard !isPresented, count > 0, let window = view.window, let content = window.contentView,
              let frame = content.superview else { return }
        isPresented = true
        Self.retained[ObjectIdentifier(self)] = self
        previousResponder = window.firstResponder

        let page = pageView ?? stage
        page.frame = frame.bounds
        page.autoresizingMask = [.width, .height]
        overlay = stage as? OverlayView
        build(in: stage)
        needsOpen = true
        frame.addSubview(page, positioned: .above, relativeTo: content)
        page.layoutSubtreeIfNeeded()
        window.makeFirstResponder(stage)
        openIfNeeded()
    }

    public func dismiss() {
        switch phase {
        case .opening, .presented, .restoring: close(velocity: .zero)
        case .dragging, .closing, .closed: break
        }
    }

    public func select(_ index: Int, animated: Bool) {
        guard overlay != nil, (0..<count).contains(index) else { return }
        if animated, phase == .presented {
            settlePager(at: index, velocity: 0)
        } else {
            pagerSprings = nil
            pagerOffset = CGFloat(index) * pageStride
            layoutPages()
        }
    }

    // MARK: State

    private enum Phase { case opening, presented, dragging, restoring, closing, closed }
    private enum Gesture { case none, paging, dismissing }

    private static var retained: [ObjectIdentifier: ImagePreviewController] = [:]

    private var phase: Phase = .closed {
        didSet { updateContentState() }
    }
    /// The content on screen, if any, and where it is; the others are off screen.
    private var shownContent: (index: Int, state: PreviewContentState)?
    private weak var previousResponder: NSResponder?
    /// The backdrop, the images and the image in flight, and what takes the clicks, swipes and keys.
    lazy var stage: NSView = OverlayView(controller: self)
    /// The stage, while it is presented.
    private var overlay: OverlayView?
    /// Presented, and waiting for the stage to be laid out in the window to open.
    private var needsOpen = false
    private let backdrop = FlippedView()
    private let pager = FlippedView()
    private let hero = HeroView()
    private var pages: [Int: PageView] = [:]

    private var contents: [Int: any PreviewContent] = [:]
    /// Pictures of thumbnails as they are on screen, for contents with no still yet.
    private var fallbacks: [Int: NSImage] = [:]

    private var heroState = HeroState.presented(.zero)
    private var springs: SpringVector?
    private var springDone: (() -> Void)?
    private var pagerOffset: CGFloat = 0
    private var pagerSprings: SpringVector?
    /// Where a drag between images would put the pager, before the rubber band.
    private var pagingOffset: CGFloat = 0
    /// Where the fingers have put the pager since the last frame; the next frame puts it there.
    private var followedOffset: CGFloat?
    /// Counts the swipes tracked by the system, so a stopped one knows it was.
    private var swipe = 0
    private var isSwiping = false
    private var ticker: FlightClock?

    private var gesture: Gesture = .none
    private var drag: DismissDrag?
    private var translation: CGPoint = .zero
    private var tracker = VelocityTracker()
    private var hiddenSource: PreviewSource?
    private var closingSource: PreviewSource?
    private var landing: Landing?
    /// Frames left in the hand-over from the landed image to its thumbnail.
    private var handoff: Int?

    /// Where the images go: the window's content area, below the title bar as the app has it
    /// (the backdrop covers it all). The viewer's own title bar can be taller; the images stay put.
    private var area: CGRect {
        guard let overlay, let window = overlay.window else { return .zero }
        if windowState == nil { titlebarInset = max(overlay.convert(window.contentLayoutRect, from: nil).minY, 0) }
        var area = overlay.bounds
        area.origin.y += titlebarInset
        area.size.height -= titlebarInset
        return area
    }
    private var titlebarInset: CGFloat = 0

    /// What the window had before the viewer took its title bar.
    private struct WindowState {
        var toolbar: NSToolbar?
        var title: String
        var transparent: Bool
        var separator: NSTitlebarSeparatorStyle
        var appearances: [(NSView, NSAppearance?)]
        /// Being given back.
        var returning = false
    }
    private var windowState: WindowState?

    /// While the viewer covers the window, the title bar is the viewer's: its title and controls, drawn
    /// dark. The window keeps its style: a toolbar gets the viewer's toolbar, a compact title bar without
    /// one (whose window has smaller corners) gets the controls at its end, never a toolbar.
    /// Whatever the change does to the app's layout happens out of sight.
    /// (Outside the frame and SwiftUI updates it may be called from: SwiftUI's toolbar must not change during them.)
    private func takeWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phase == .presented, self.windowState == nil else { return }
            let page = self.pageView ?? self.stage
            guard let window = page.window, let frame = page.superview else { return }
            _ = self.area
            // The title bar: what the window draws above the page.
            let titlebar = Array(frame.subviews.drop { $0 !== page }.dropFirst())
            self.windowState = WindowState(
                toolbar: window.toolbar, title: window.title, transparent: window.titlebarAppearsTransparent,
                separator: window.titlebarSeparatorStyle, appearances: titlebar.map { ($0, $0.appearance) }
            )
            // Nothing behind the title bar but the backdrop; light controls over it.
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            titlebar.forEach { $0.appearance = NSAppearance(named: .darkAqua) }
            let hasToolbar = window.toolbar != nil
            if let titlebarView = self.makeTitlebar?(hasToolbar) {
                titlebarView.frame = .zero
                frame.addSubview(titlebarView, positioned: .below, relativeTo: page)
                self.titlebarView = titlebarView
            } else {
                if hasToolbar { window.toolbar = PreviewToolbar(controller: self) }
                if let title = self.title { window.title = title }
            }
            if !hasToolbar {
                let controls = NSTitlebarAccessoryViewController()
                controls.view = self.makeTitlebarControls?() ?? self.appKitControls()
                controls.layoutAttribute = .trailing
                window.addTitlebarAccessoryViewController(controls)
                self.titlebarControls = controls
            }
            self.showControls()
        }
    }

    /// A click on an image hides and shows the controls.
    private func showControls() {
        guard windowState?.returning == false else { return }
        if let titlebarControls {
            titlebarControls.isHidden = !context.accessoriesVisible
        } else {
            (pageView ?? stage).window?.toolbar?.isVisible = context.accessoriesVisible
        }
    }

    /// The actions view and a close button, for a title bar without a toolbar.
    private func appKitControls() -> NSView {
        let close = NSButton(image: Self.closeImage, target: closeTarget, action: #selector(CloseTarget.close))
        close.bezelStyle = .accessoryBarAction
        let stack = NSStackView(views: [actionsView, close].compactMap { $0 })
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.frame.size = stack.fittingSize
        return stack
    }

    static let closeImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!

    lazy var closeTarget = CloseTarget(self)

    /// What a close button sends its action to.
    @MainActor final class CloseTarget: NSObject {
        weak var controller: ImagePreviewController?
        init(_ controller: ImagePreviewController) { self.controller = controller }
        @objc func close() { controller?.dismiss() }
    }

    /// As soon as anything of the window shows through (a drag, closing), it is the app's again.
    private func giveWindowBack() {
        guard let state = windowState, !state.returning, let window = (pageView ?? stage).window else { return }
        windowState?.returning = true
        DispatchQueue.main.async { [weak self] in
            self?.titlebarView?.removeFromSuperview()
            self?.titlebarView = nil
            self?.titlebarControls?.removeFromParent()
            self?.titlebarControls = nil
            window.toolbar = state.toolbar
            window.title = state.title
            window.titlebarAppearsTransparent = state.transparent
            window.titlebarSeparatorStyle = state.separator
            state.appearances.forEach { $0.appearance = $1 }
            self?.windowState = nil
        }
    }
    private var pageStride: CGFloat { area.width + configuration.pageSpacing }

    // MARK: Building

    private func build(in view: NSView) {
        guard ticker == nil, let overlay = view as? OverlayView else { return }
        ticker = FlightClock(view: overlay) { [weak self] dt in self?.tick(dt) }
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = configuration.backgroundColor
        backdrop.alphaValue = 0
        pager.isHidden = true
        hero.isHidden = true
        for view in [backdrop, pager, hero] as [NSView] {
            view.frame = overlay.bounds
            view.autoresizingMask = view === pager ? [] : [.width, .height]
            overlay.addSubview(view)
        }

        let doubleClick = NSClickGestureRecognizer(target: overlay, action: #selector(OverlayView.doubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        let click = NSClickGestureRecognizer(target: overlay, action: #selector(OverlayView.click(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        click.delegate = overlay
        overlay.doubleClickRecognizer = doubleClick
        let pan = NSPanGestureRecognizer(target: overlay, action: #selector(OverlayView.pan(_:)))
        pan.delaysPrimaryMouseButtonEvents = false
        [doubleClick, click, pan].forEach(overlay.addGestureRecognizer)
    }

    fileprivate func layout() {
        guard let overlay, overlay.bounds.width > 0 else { return }
        if needsOpen { return openIfNeeded() }
        pager.frame = area
        // A swipe or a spring moving the pager has it between images; changing the image re-lays out the stage.
        if pagerSprings == nil, !isSwiping, gesture != .paging { pagerOffset = CGFloat(index) * pageStride }
        for page in pages.values { page.refit() }
        layoutPages()
        switch phase {
        case .opening, .restoring, .closing: retargetHero()
        case .presented, .dragging, .closed: break
        }
    }

    // MARK: Contents

    /// The content at an index, loading from the first time it is wanted.
    private func content(_ i: Int) -> any PreviewContent {
        if let content = contents[i] { return content }
        let content = contentProvider(i)
        contents[i] = content
        content.load { [weak self] in self?.didLoad(at: i) }
        return content
    }

    private func updateContentState() {
        let state: PreviewContentState
        switch phase {
        case .presented: state = .onScreen
        case .opening, .dragging, .restoring, .closing: state = .moving
        case .closed: state = .offScreen
        }
        let now = state == .offScreen ? nil : (index: index, state: state)
        if let shown = shownContent, shown.index != now?.index { contents[shown.index]?.setState(.offScreen) }
        if let now, shownContent?.index != now.index || shownContent?.state != now.state { content(now.index).setState(now.state) }
        shownContent = now
    }

    /// The best picture to draw for an index right now.
    private func currentImage(_ i: Int) -> NSImage? {
        content(i).still() ?? fallbacks[i]
    }

    private func didLoad(at i: Int) {
        guard let image = currentImage(i) else { return }
        pages[i]?.setImage(image, fade: true)
        if i == index, !hero.isHidden {
            hero.setImage(image, fade: true)
            retargetHero()
        }
    }

    // MARK: Pages

    private func layoutPages() {
        guard area.width > 0 else { return }
        let position = pagerOffset / pageStride
        let visible = Int(floor(position))...Int(ceil(position))
        let wanted = Set((visible.lowerBound - 1...visible.upperBound + 1).filter { (0..<count).contains($0) })
        for (i, page) in pages where !wanted.contains(i) {
            page.removeFromSuperview()
            pages[i] = nil
        }
        for i in wanted where pages[i] == nil {
            let page = PageView(controller: self)
            page.maximumZoomFactor = configuration.maximumZoomScale
            pager.addSubview(page)
            pages[i] = page
            page.frame = pageFrame(i)
            page.setImage(currentImage(i), fade: false)
            page.setLiveView(content(i).makeView(for: .page))
        }
        for (i, page) in pages {
            let frame = pageFrame(i)
            if page.frame.size != frame.size {
                page.frame = frame
                page.refit()
            } else {
                page.setFrameOrigin(frame.origin)
            }
            if !visible.contains(i) { page.resetZoom() }
        }
        let i = Int(position.rounded())
        if (0..<count).contains(i), i != index { setIndex(i) }
    }

    private func pageFrame(_ i: Int) -> CGRect {
        CGRect(x: CGFloat(i) * pageStride - pagerOffset, y: 0, width: area.width, height: area.height)
    }

    private func setIndex(_ i: Int) {
        guard i != context.index else { return }
        context.index = i
        updateContentState()
        if phase != .closed, phase != .closing { hideSource() }
        onIndexChange?(i)
    }

    private var currentPage: PageView? { pages[index] }

    /// Springs the pager to a page, carrying the drag's velocity.
    private func settlePager(at target: Int, velocity: CGFloat) {
        stopSwipe()
        if let followedOffset { pagerOffset = followedOffset }
        followedOffset = nil
        let target = min(max(target, 0), count - 1)
        var springs = pagerSprings ?? SpringVector(values: [Double(pagerOffset)], tolerances: [0.3], spring: PreviewSpring(response: 0.3, dampingRatio: 1))
        springs.set(values: [Double(pagerOffset)], velocities: [Double(min(max(velocity, -4000), 4000))])
        springs.retarget([Double(CGFloat(target) * pageStride)])
        pagerSprings = springs
        ticker?.start()
    }

    // MARK: Sources

    private func hideSource() {
        let source = sourceProvider(index)
        if hiddenSource?.view !== source?.view { hiddenSource?.setHidden(false) }
        source?.setHidden(true)
        hiddenSource = source
    }

    private func visibleFrame(of source: PreviewSource?) -> CGRect? {
        guard let frame = frame(of: source), let overlay, frame.intersects(overlay.bounds) else { return nil }
        return frame
    }

    /// The thumbnail's frame in the viewer, on screen or not, while it is in the viewer's window.
    private func frame(of source: PreviewSource?) -> CGRect? {
        guard let view = source?.view, let overlay, view.window === overlay.window else { return nil }
        let frame = view.convert(view.bounds, to: overlay)
        return frame.width > 1 && frame.height > 1 ? frame : nil
    }

    private func snapshot(_ source: PreviewSource?) -> NSImage? {
        guard let view = source?.view, let content = view.window?.contentView else { return nil }
        let rect = view.convert(view.bounds, to: content)
        guard rect.width > 1, rect.height > 1, let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    private func sourceState(_ source: PreviewSource?, at frame: CGRect? = nil) -> HeroState? {
        guard let source, let frame = frame ?? visibleFrame(of: source), let size = hero.image?.size else { return nil }
        let mode = hero.image != nil && hero.image === fallbacks[index] ? PreviewContentMode.fit : source.contentMode
        return .source(frame: frame, imageSize: size, mode: mode, cornerRadius: source.cornerRadius)
    }

    // MARK: Opening and closing

    private var fittedFrame: CGRect { area.placing(hero.image?.size ?? .zero, .fit) }

    /// Opens once the stage has its size in the window.
    private func openIfNeeded() {
        guard needsOpen, let overlay, overlay.window != nil, overlay.bounds.width > 0 else { return }
        needsOpen = false
        pager.frame = area
        pagerOffset = CGFloat(index) * pageStride
        open()
    }

    private func open() {
        let source = sourceProvider(index)
        if currentImage(index) == nil, let snap = snapshot(source) { fallbacks[index] = snap }
        layoutPages()
        showHero(currentImage(index))
        phase = .opening
        hideSource()
        setHero((reduceMotion ? nil : sourceState(source)) ?? .vanished(from: fittedFrame))
        animateHero(to: .presented(fittedFrame), spring: configuration.transitionSpring) { [weak self] in
            self?.didSettlePresented()
        }
    }

    private func didSettlePresented() {
        phase = .presented
        currentPage?.setImage(currentImage(index), fade: false)
        pager.isHidden = false
        hideHero()
        takeWindow()
    }

    /// Shows the content on screen in the hero: the still, and the content's view over it.
    private func showHero(_ still: NSImage?) {
        hero.setImage(still, fade: false)
        hero.setLiveView(content(index).makeView(for: .flight))
        hero.isHidden = false
    }

    private func hideHero() {
        hero.isHidden = true
        hero.setLiveView(nil)
    }

    private func liftHero() {
        guard let overlay, let page = currentPage else { return }
        let image = page.imageFrame(in: overlay)
        showHero(currentImage(index) ?? page.image)
        setHero(HeroState(image: image, clip: image.intersection(overlay.bounds), cornerRadius: 0, backdrop: 1))
        pager.isHidden = true
    }

    private func close(velocity: CGPoint) {
        if phase == .presented { liftHero() }
        phase = .closing
        giveWindowBack()
        onDismiss?()
        let source = sourceProvider(index)
        if hiddenSource?.view !== source?.view { hiddenSource?.setHidden(false) }
        hiddenSource = source
        source?.setHidden(true)
        closingSource = source
        let target = closedTarget(source)
        animateHero(to: target, spring: configuration.transitionSpring, velocity: velocity) { [weak self] in
            self?.didClose()
        }
        // Flying home to a thumbnail: follow it if the page scrolls under it.
        if target.backdrop == 0, target.opacity > 0, let frame = visibleFrame(of: source), let springs {
            landing = Landing(frame: frame, springs: springs)
        }
    }

    private func closedTarget(_ source: PreviewSource?) -> HeroState {
        (reduceMotion ? nil : sourceState(source)) ?? .vanished(from: heroState.image)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func didClose() {
        phase = .closed
        closingSource?.setHidden(false)
        hiddenSource = nil
        landing = nil
        contents.values.forEach { $0.cancel() }
        onDidDismiss?()
        handOverOrFinish()
    }

    /// The thumbnail shows again a frame or two after it is told to (SwiftUI may take one more).
    /// Until it surely has, the landed image stays pinned on it, following it if the page is
    /// scrolling, so the two never part; then the image goes.
    private func handOverOrFinish() {
        guard heroState.opacity > 0, closingSource != nil else { return finish() }
        handoff = 4
        ticker?.start()
    }

    private func handOver(_ frames: Int) {
        if let frame = frame(of: closingSource), let state = sourceState(closingSource, at: frame) { setHero(state) }
        if frames > 1 { handoff = frames - 1 } else { finish() }
    }

    private func finish() {
        handoff = nil
        hideHero()
        closingSource = nil
        ticker?.stop()
        giveWindowBack()
        let window = overlay?.window
        (pageView ?? stage).removeFromSuperview()
        overlay = nil
        if let previousResponder, window?.firstResponder == nil || window?.firstResponder === window {
            window?.makeFirstResponder(previousResponder)
        }
        isPresented = false
        Self.retained[ObjectIdentifier(self)] = nil
    }

    private func retargetHero() {
        guard springs != nil else { return }
        switch phase {
        case .opening, .restoring: springs?.retarget(HeroState.presented(fittedFrame).vector)
        case .closing: springs?.retarget(closedTarget(closingSource).vector)
        case .presented, .dragging, .closed: break
        }
        ticker?.start()
    }

    private func restore(velocity: CGPoint) {
        phase = .restoring
        animateHero(to: .presented(fittedFrame), spring: configuration.restoreSpring, velocity: velocity) { [weak self] in
            self?.didSettlePresented()
        }
    }

    // MARK: Gestures

    /// A drag or two-finger swipe starts: sideways moves between images, up or down closes.
    fileprivate func beginGesture(at point: CGPoint, direction: CGPoint) {
        tracker = VelocityTracker()
        translation = .zero
        let zoomed = currentPage?.isZoomed == true
        // Up or down closes; so does sideways past the first or last image. Other sideways moves page.
        guard let axis = DismissDrag.axis(for: direction, index: index, count: count) else {
            guard phase == .presented, count > 1, !zoomed else { return gesture = .none }
            stopSwipe()
            pagerSprings = nil
            pagingOffset = pagerOffset
            gesture = .paging
            return
        }
        switch phase {
        case .presented where !zoomed: liftHero()
        case .opening, .restoring: break
        default: return gesture = .none
        }
        stopSprings()
        // The pager, now hidden, waits on the image for when the image goes back.
        stopSwipe()
        pagerSprings = nil
        followedOffset = nil
        pagerOffset = CGFloat(index) * pageStride
        layoutPages()
        giveWindowBack()
        phase = .dragging
        drag = DismissDrag(start: heroState, anchor: point, axis: axis, container: area.size)
        gesture = .dismissing
    }

    fileprivate func moveGesture(by delta: CGPoint, time: TimeInterval) {
        tracker.add(delta, at: time)
        switch gesture {
        case .paging:
            pagingOffset -= delta.x
            follow(rubberBanded(pagingOffset))
        case .dismissing:
            translation.x += delta.x
            translation.y += delta.y
            if let drag { setHero(drag.state(translation: translation)) }
        case .none:
            break
        }
    }

    fileprivate func endGesture() {
        let v = tracker.velocity
        switch gesture {
        case .paging:
            finishPaging(around: index, velocity: -v.x)
        case .dismissing:
            let closes = drag?.closes(translation: translation, velocity: v) == true
            drag = nil
            if closes {
                close(velocity: v)
            } else {
                restore(velocity: v)
            }
        case .none:
            break
        }
        gesture = .none
    }

    /// Where the pager is for where the drag would put it: past the first or last image it gives
    /// less and less, like a scroll view's rubber band.
    private func rubberBanded(_ offset: CGFloat) -> CGFloat {
        let limit = CGFloat(count - 1) * pageStride
        let width = max(area.width, 1)
        func band(_ over: CGFloat) -> CGFloat { (1 - 1 / (over * 0.55 / width + 1)) * width }
        if offset < 0 { return -band(-offset) }
        if offset > limit { return limit + band(offset - limit) }
        return offset
    }

    /// Moves the pager where the fingers put it, on the next frame: in step with the display,
    /// however the fingers' moves arrive.
    private func follow(_ offset: CGFloat) {
        followedOffset = offset
        ticker?.start()
    }

    /// Springs the pager to the image the fingers left it nearest, or on to the next one in the
    /// direction they flicked, at most one away from `page`.
    private func finishPaging(around page: Int, velocity: CGFloat) {
        let offset = followedOffset ?? pagerOffset
        let projected = (offset + velocity * 0.15) / pageStride
        let target = Int(min(max(projected.rounded(), CGFloat(page - 1)), CGFloat(page + 1)))
        settlePager(at: target, velocity: velocity)
    }

    /// A two-finger swipe between images, followed the way the system follows swipes between pages:
    /// as far as the fingers go, rubber-banding where there is no image. When the fingers lift, the
    /// pager's spring finishes it, carrying their speed, like moving with the arrow keys. Off when
    /// the person has turned off swiping between pages; then the swipe's scroll moves the pager.
    fileprivate func trackSwipe(_ event: NSEvent) -> Bool {
        guard gesture == .paging, NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return false }
        // The swipe starts where the pager is, which is between images when one starts before the
        // last has settled, and goes to the image before or after the one it was headed for.
        let from = pagerOffset
        let start = Int((from / pageStride).rounded())
        let previous = start > 0 ? CGFloat(start - 1) * pageStride : from - pageStride
        let next = start < count - 1 ? CGFloat(start + 1) * pageStride : from + pageStride
        swipe += 1
        let swipe = swipe
        isSwiping = true
        gesture = .none
        var last = from
        // The amount is positive for a swipe to the right, toward the previous image.
        event.trackSwipeEvent(
            options: [],
            dampenAmountThresholdMin: start < count - 1 ? -1 : 0,
            max: start > 0 ? 1 : 0
        ) { [weak self] amount, phase, _, stop in
            guard let self, self.swipe == swipe else {
                stop.pointee = true
                return
            }
            guard self.phase == .presented, self.pageStride > 0 else {
                self.isSwiping = false
                stop.pointee = true
                return
            }
            let offset = from - amount * (amount > 0 ? from - previous : next - from)
            self.tracker.add(CGPoint(x: last - offset, y: 0), at: ProcessInfo.processInfo.systemUptime)
            last = offset
            self.follow(offset)
            guard phase == .ended || phase == .cancelled else { return }
            stop.pointee = true
            self.finishPaging(around: start, velocity: phase == .ended ? -self.tracker.velocity.x : 0)
        }
        return true
    }

    /// Stops following a swipe, leaving the pager where it is.
    private func stopSwipe() {
        guard isSwiping else { return }
        swipe += 1
        isSwiping = false
    }

    fileprivate func handleClick(at point: CGPoint) {
        guard phase == .presented, let overlay else { return }
        let onImage = currentPage?.imageFrame(in: overlay).contains(point) == true
        if !onImage { dismiss() } else if configuration.tapTogglesAccessories {
            context.accessoriesVisible.toggle()
            showControls()
        }
    }

    fileprivate func handleDoubleClick(at point: CGPoint) {
        guard phase == .presented, let overlay, let page = currentPage else { return }
        page.toggleZoom(at: overlay.convert(point, to: page))
    }

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53, 49: dismiss()
        case 123: select(index - 1, animated: true)
        case 124: select(index + 1, animated: true)
        default: return false
        }
        return true
    }

    // MARK: Animation

    private func setHero(_ state: HeroState) {
        heroState = state
        hero.apply(state)
        backdrop.alphaValue = state.backdrop
        springs?.set(values: state.vector)
    }

    private func animateHero(to target: HeroState, spring: PreviewSpring, velocity: CGPoint = .zero, completion: @escaping () -> Void) {
        var springs = springs ?? SpringVector(values: heroState.vector, tolerances: HeroState.tolerances, spring: spring)
        if self.springs == nil || velocity != .zero {
            springs.set(values: heroState.vector, velocities: velocity == .zero ? nil : heroState.velocity(velocity, toward: target))
        }
        springs.retarget(target.vector, spring: spring)
        self.springs = springs
        springDone = completion
        ticker?.start()
    }

    private func stopSprings() {
        springs = nil
        springDone = nil
    }

    private func tick(_ dt: Double) {
        if let handoff { return handOver(handoff) }
        if let followedOffset {
            pagerOffset = followedOffset
            self.followedOffset = nil
            layoutPages()
        }
        if var pagerSprings {
            let done = pagerSprings.step(dt)
            self.pagerSprings = done ? nil : pagerSprings
            pagerOffset = CGFloat(pagerSprings.values[0])
            layoutPages()
        }
        if var springs {
            if phase == .closing, var landing, let frame = frame(of: closingSource) {
                if !landing.follow(frame, springs: &springs), let target = sourceState(closingSource) {
                    springs.retarget(target.vector)
                }
                self.landing = landing
            }
            let done = springs.step(dt)
            self.springs = springs
            heroState = HeroState(springs.values)
            hero.apply(heroState)
            backdrop.alphaValue = heroState.backdrop
            if done {
                let completion = springDone
                stopSprings()
                completion?()
            }
        }
        if springs == nil, pagerSprings == nil, handoff == nil, !isSwiping, gesture != .paging { ticker?.stop() }
    }

    // MARK: Views

    /// Covers the window; takes the clicks, drags, swipes and keys meant for the viewer.
    fileprivate final class OverlayView: NSView, NSGestureRecognizerDelegate {
        weak var controller: ImagePreviewController?
        weak var doubleClickRecognizer: NSGestureRecognizer?
        private var scrollBegan = false

        init(controller: ImagePreviewController) {
            self.controller = controller
            super.init(frame: .zero)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        // While the image flies home, the window underneath takes clicks and scrolls again.
        override func hitTest(_ point: NSPoint) -> NSView? {
            controller?.isClosing == true ? nil : super.hitTest(point)
        }

        override func layout() {
            super.layout()
            controller?.layout()
        }

        override func keyDown(with event: NSEvent) {
            if controller?.handleKey(event) != true { super.keyDown(with: event) }
        }

        override func cancelOperation(_ sender: Any?) { controller?.dismiss() }

        // A click waits to see whether it is the first of a double click.
        func gestureRecognizer(_ g: NSGestureRecognizer, shouldRequireFailureOf other: NSGestureRecognizer) -> Bool {
            other === doubleClickRecognizer
        }

        // Clicks must not reach the window underneath.
        override func mouseDown(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}

        @objc func click(_ g: NSClickGestureRecognizer) {
            controller?.handleClick(at: g.location(in: self))
        }

        @objc func doubleClick(_ g: NSClickGestureRecognizer) {
            controller?.handleDoubleClick(at: g.location(in: self))
        }

        @objc func pan(_ g: NSPanGestureRecognizer) {
            guard let controller else { return }
            switch g.state {
            case .began:
                let t = g.translation(in: self)
                controller.beginGesture(at: g.location(in: self), direction: t)
                controller.moveGesture(by: t, time: ProcessInfo.processInfo.systemUptime)
                g.setTranslation(.zero, in: self)
            case .changed:
                controller.moveGesture(by: g.translation(in: self), time: ProcessInfo.processInfo.systemUptime)
                g.setTranslation(.zero, in: self)
            case .ended, .cancelled:
                controller.endGesture()
            default:
                break
            }
        }

        /// Two-finger swipes: sideways moves between images, up or down closes. The momentum
        /// that follows a swipe is ignored; the springs finish a swipe, carrying its velocity.
        func scrollGesture(_ event: NSEvent) -> Bool {
            guard let controller, event.hasPreciseScrollingDeltas, event.momentumPhase == [] else {
                return event.momentumPhase != []
            }
            let delta = CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                scrollBegan = false
                return true
            }
            if event.phase.contains(.changed) {
                if !scrollBegan {
                    guard delta != .zero else { return true }
                    scrollBegan = true
                    controller.beginGesture(at: convert(event.locationInWindow, from: nil), direction: delta)
                    if controller.trackSwipe(event) { return true }
                }
                controller.moveGesture(by: delta, time: event.timestamp)
                return true
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                if scrollBegan { controller.endGesture() }
                scrollBegan = false
                return true
            }
            return false
        }

        override func scrollWheel(with event: NSEvent) {
            if !scrollGesture(event) { super.scrollWheel(with: event) }
        }
    }

    /// One page: its still fitted to the window and the content's view over it; pinch or double-click to zoom.
    fileprivate final class PageView: NSScrollView {
        weak var controller: ImagePreviewController?
        let imageView = LayerImageView()
        var maximumZoomFactor: CGFloat = 4
        private var imageSize: CGSize = .zero

        init(controller: ImagePreviewController) {
            self.controller = controller
            super.init(frame: .zero)
            contentView = CenteringClipView()
            automaticallyAdjustsContentInsets = false
            drawsBackground = false
            hasVerticalScroller = false
            hasHorizontalScroller = false
            allowsMagnification = true
            scrollerStyle = .overlay
            documentView = imageView
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        var image: NSImage? { imageView.image }
        var isZoomed: Bool { magnification > minMagnification + 0.01 }

        /// The content's view, over the still; clicks go past it, to the viewer.
        func setLiveView(_ view: NSView?) {
            guard let view else { return }
            let container = ClickThroughView(frame: imageView.bounds)
            container.autoresizingMask = [.width, .height]
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            imageView.addSubview(container)
        }

        func setImage(_ image: NSImage?, fade: Bool) {
            imageView.setImage(image, fade: fade)
            let size = image?.size ?? .zero
            let sameShape = size.hasArea && imageSize.hasArea
                && abs(size.width / size.height - imageSize.width / imageSize.height) < 0.002
            imageSize = size
            if !sameShape { refit() }
        }

        func refit() {
            magnification = 1
            let fitted = CGRect(origin: .zero, size: bounds.size).placing(imageSize, .fit)
            imageView.frame = CGRect(origin: .zero, size: fitted.size)
            minMagnification = 1
            let fill = fitted.width > 0 ? max(bounds.width / fitted.width, bounds.height / fitted.height) : 1
            maxMagnification = max(maximumZoomFactor, fill)
        }

        func resetZoom() {
            if isZoomed { magnification = minMagnification }
        }

        func imageFrame(in view: NSView) -> CGRect {
            imageView.convert(imageView.bounds, to: view)
        }

        func toggleZoom(at point: CGPoint) {
            let target: CGFloat
            if isZoomed {
                target = minMagnification
            } else {
                let fitted = imageView.frame.size
                let fill = fitted.width > 0 ? max(bounds.width / fitted.width, bounds.height / fitted.height) : 2.5
                target = min(fill > 1.25 ? fill : 2.5, maxMagnification)
            }
            let center = convert(point, to: imageView)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                context.allowsImplicitAnimation = true
                setMagnification(target, centeredAt: center)
            }
        }

        override func scrollWheel(with event: NSEvent) {
            if !isZoomed, let overlay = controller?.overlay, overlay.scrollGesture(event) { return }
            super.scrollWheel(with: event)
        }
    }

    /// Keeps an image smaller than the window in its middle.
    private final class CenteringClipView: NSClipView {
        override var isFlipped: Bool { true }

        override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
            var rect = super.constrainBoundsRect(proposed)
            guard let document = documentView else { return rect }
            if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
            if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
            return rect
        }
    }

    /// The moving image: a clipping frame with rounded corners, the whole image inside it.
    private final class HeroView: FlippedView {
        let clipView = FlippedView()
        let imageView = LayerImageView()

        override init(frame: NSRect) {
            super.init(frame: frame)
            clipView.wantsLayer = true
            clipView.layer?.masksToBounds = true
            clipView.layer?.cornerCurve = .continuous
            clipView.addSubview(imageView)
            addSubview(clipView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        var image: NSImage? { imageView.image }

        func setImage(_ image: NSImage?, fade: Bool) { imageView.setImage(image, fade: fade) }

        private var liveView: NSView?

        /// The content's view, over the still.
        func setLiveView(_ view: NSView?) {
            liveView?.removeFromSuperview()
            liveView = view
            guard let view else { return }
            view.frame = imageView.bounds
            view.autoresizingMask = [.width, .height]
            imageView.addSubview(view)
        }

        func apply(_ state: HeroState) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clipView.frame = state.clip
            clipView.layer?.cornerRadius = min(state.cornerRadius, min(state.clip.width, state.clip.height) / 2)
            imageView.frame = state.image.offsetBy(dx: -state.clip.minX, dy: -state.clip.minY)
            clipView.alphaValue = state.opacity
            CATransaction.commit()
        }
    }
}

/// The toolbar the viewer puts on a window that has one, for AppKit code: the close button, then the actions view.
private final class PreviewToolbar: NSToolbar, NSToolbarDelegate {
    private weak var controller: ImagePreviewController?
    private static let close = NSToolbarItem.Identifier("preview.close")
    private static let actions = NSToolbarItem.Identifier("preview.actions")

    init(controller: ImagePreviewController) {
        self.controller = controller
        super.init(identifier: "preview")
        delegate = self
        displayMode = .iconOnly
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.close, .flexibleSpace] + (controller?.actionsView == nil ? [] : [Self.actions])
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == Self.close {
            item.image = ImagePreviewController.closeImage
            item.label = "Close"
            item.target = controller?.closeTarget
            item.action = #selector(ImagePreviewController.CloseTarget.close)
        } else {
            item.view = controller?.actionsView
        }
        return item
    }
}

/// An image drawn by its layer, stretched to the view's bounds.
final class LayerImageView: NSView {
    private(set) var image: NSImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setImage(_ image: NSImage?, fade: Bool) {
        self.image = image
        // The picture alone fades, not the content's view on it.
        if fade {
            let transition = CABasicAnimation(keyPath: "contents")
            transition.fromValue = layer?.contents
            transition.duration = 0.2
            layer?.add(transition, forKey: "preview.fade")
        }
        layer?.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Holds a view that is only to be seen.
private final class ClickThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The velocity of a drag, from its last few movements.
struct VelocityTracker {
    private var samples: [(delta: CGPoint, time: TimeInterval)] = []

    mutating func add(_ delta: CGPoint, at time: TimeInterval) {
        samples.append((delta, time))
        samples.removeAll { time - $0.time > 0.1 }
    }

    var velocity: CGPoint {
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.005 else { return .zero }
        let total = samples.dropFirst().reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.delta.x, y: $0.y + $1.delta.y) }
        let dt = last.time - first.time
        return CGPoint(x: total.x / dt, y: total.y / dt)
    }
}
#endif
