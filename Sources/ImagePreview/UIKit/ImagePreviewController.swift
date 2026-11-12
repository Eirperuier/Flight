#if canImport(UIKit)
import UIKit

/// Shows images full screen, opening out of the thumbnail that was tapped and closing back into it.
///
/// Swipe between images, pinch or double-tap to zoom, and drag an image in any direction
/// to close it: it follows the finger, shrinks, and lets what is underneath show through;
/// let go and it flies back into its thumbnail, or springs back if the drag was not far or fast enough.
///
/// ```swift
/// let preview = ImagePreviewController(count: photos.count, index: tapped) { i in
///     PreviewImage(url: photos[i].url, placeholder: cells[i].imageView.image)
/// } source: { i in
///     PreviewSource(view: cells[i].imageView, cornerRadius: 8)
/// }
/// preview.present(from: view)
/// ```
///
/// The viewer is a page presented over the view controller `view` is in, inside a navigation
/// controller of its own: put buttons on its navigation bar and toolbar through ``page``.
@MainActor
public final class ImagePreviewController {
    /// What the accessories can read (the index, whether they are showing) and do.
    public let context: ImagePreviewContext
    public var configuration: ImagePreviewConfiguration
    /// The image on screen changed (a swipe, or `select`).
    public var onIndexChange: ((Int) -> Void)?
    /// The viewer started closing.
    public var onDismiss: (() -> Void)?
    /// The viewer finished closing and is gone.
    public var onDidDismiss: (() -> Void)?
    /// The page in the viewer's navigation controller. Set its `navigationItem` and `toolbarItems`
    /// for the bars over the images, which a tap hides and shows and a drag fades.
    public var page: UIViewController { pageController ?? stage }

    /// A page that shows the stage inside other content (a SwiftUI hosting controller), set before presenting.
    var pageController: UIViewController?

    /// The image on screen.
    public var index: Int { context.index }
    public private(set) var isPresented = false
    var isClosing: Bool { phase == .closing || phase == .closed }

    private let count: Int
    private let contentProvider: (Int) -> any PreviewContent
    private let sourceProvider: (Int) -> PreviewSource?

    /// - Parameters:
    ///   - count: How many images there are.
    ///   - index: The image to open.
    ///   - image: The image or video at an index (a ``PreviewImage``, a ``PreviewVideo``, or
    ///     ``PreviewMedia`` for either); asked for when it is about to be shown.
    ///   - source: The thumbnail of the image at an index, if it is on screen.
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

    /// Opens the viewer over the view controller `view` is in.
    public func present(from view: UIView) {
        guard !isPresented, count > 0, var presenter = view.closestViewController else { return }
        // A viewer still putting its last image home goes now (its image lands at once).
        for other in Self.retained.values where other.phase == .closed || other.phase == .closing { other.landNow() }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }
        isPresented = true
        Self.retained[ObjectIdentifier(self)] = self

        let navigation = PreviewNavigationController(controller: self, page: page)
        navigation.modalPresentationStyle = .custom
        navigation.transitioningDelegate = transitioning
        navigation.modalPresentationCapturesStatusBarAppearance = true
        self.navigation = navigation
        needsOpen = true
        // Without animation: the images move by the viewer's own springs, from the first frame.
        presenter.present(navigation, animated: false)
    }

    /// Closes the viewer, into the thumbnail of the image on screen if it is visible.
    public func dismiss() {
        switch phase {
        case .opening, .presented, .restoring:
            close(velocity: .zero)
        case .dragging, .closing, .closed:
            break
        }
    }

    /// Shows the image at `index`.
    public func select(_ index: Int, animated: Bool) {
        guard isLoaded, (0..<count).contains(index) else { return }
        pager.setContentOffset(CGPoint(x: CGFloat(index) * pager.bounds.width, y: 0), animated: animated && phase == .presented)
        if !animated || phase != .presented { setIndex(index) }
    }

    // MARK: State

    private enum Phase { case opening, presented, dragging, restoring, closing, closed }

    /// Viewers on screen keep themselves alive until they have closed.
    private static var retained: [ObjectIdentifier: ImagePreviewController] = [:]

    private var phase: Phase = .closed {
        didSet { updateContentState() }
    }
    /// The content on screen, if any, and where it is; the others are off screen.
    private var shownContent: (index: Int, state: PreviewContentState)?
    private var navigation: PreviewNavigationController?
    lazy var stage = PreviewStageViewController(controller: self)
    private let transitioning = PreviewTransitioning()
    /// Presented, and waiting for the stage to be on screen to open.
    private var needsOpen = false
    private var root: UIView? { stage.viewIfLoaded }
    private var isLoaded: Bool { stage.isViewLoaded }

    private let backdrop = UIView()
    private let pager = PreviewPagerView()
    private let hero = HeroView()
    private var pages: [Int: PreviewPageView] = [:]
    private var isLayingOut = false

    private var contents: [Int: any PreviewContent] = [:]
    /// Pictures of thumbnails as they are on screen, for contents with no still yet.
    private var fallbacks: [Int: UIImage] = [:]

    private var heroState = HeroState.presented(.zero)
    /// The flight between the thumbnail and full screen, among the page's layers.
    private var flight: PreviewFlight?
    private var flightDone: (() -> Void)?
    /// Closing: the image as it was let go, which it changes from into its thumbnail.
    private var flightStart: HeroState?
    /// Which flight a plan being chosen elsewhere is for.
    private var flightSerial = 0
    /// The layers over the thumbnail the image flies from or to.
    private var layers: PreviewLayers?
    private var springs: SpringVector?
    private var springDone: (() -> Void)?
    private lazy var ticker = FlightClock { [weak self] dt in self?.tick(dt) }

    private var drag: DismissDrag?
    private var dragAxis: DismissDrag.Axis = .vertical
    private var hiddenSource: PreviewSource?
    private var closingSource: PreviewSource?
    private var landing: Landing?
    /// Frames left in the hand-over from the landed image to its thumbnail.
    private var handoff: Int?
    /// How much the bars show: 0 while they are hidden, before opening and while dragging.
    fileprivate var barsAlpha: CGFloat = 0
    /// The status bar is drawn as the app draws it, not light over the dark backdrop.
    private var statusBarFollowsApp = false

    private lazy var gestureTarget = GestureTarget(self)
    private lazy var dismissPan = UIPanGestureRecognizer(target: gestureTarget, action: #selector(GestureTarget.pan(_:)))
    private lazy var singleTap = UITapGestureRecognizer(target: gestureTarget, action: #selector(GestureTarget.tap(_:)))
    private lazy var doubleTap = UITapGestureRecognizer(target: gestureTarget, action: #selector(GestureTarget.doubleTap(_:)))
    private lazy var gestureDelegate = GestureDelegate(self)

    // MARK: Building

    fileprivate func load(into view: UIView) {
        view.backgroundColor = .clear
        backdrop.backgroundColor = UIColor(cgColor: configuration.backgroundColor)
        backdrop.alpha = 0
        view.addSubview(backdrop)

        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.showsVerticalScrollIndicator = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.scrollsToTop = false
        pager.hidesEdgeEffects()
        pager.delegate = gestureDelegate
        pager.isHidden = true
        // On an unzoomed image, a drag up or down, or sideways past the first or last image,
        // is the drag that closes, not a swipe.
        pager.shouldBeginPan = { [weak self] velocity in
            guard let self else { return true }
            return self.currentPage?.isZoomed == true || self.dismissAxis(for: velocity) == nil
        }
        view.addSubview(pager)

        hero.isUserInteractionEnabled = false
        view.addSubview(hero)

        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        [dismissPan, singleTap, doubleTap].forEach { $0.delegate = gestureDelegate }
        dismissPan.maximumNumberOfTouches = 1
        #if targetEnvironment(macCatalyst)
        // A two-finger swipe on the trackpad closes too, following the fingers, as a drag does
        // (and as the viewer on the Mac does). The pager takes the sideways ones that page.
        // Never the pointer's click and drag: an image dragged by the mouse isn't how anything
        // moves on the Mac.
        dismissPan.allowedScrollTypesMask = .continuous
        dismissPan.allowedTouchTypes = []
        #endif
        [dismissPan, singleTap, doubleTap].forEach(view.addGestureRecognizer)
    }

    fileprivate func layout(in view: UIView) {
        let bounds = view.bounds
        backdrop.frame = bounds
        if hero.superview === view {
            hero.transform = .identity
            hero.frame = bounds
        }

        let width = bounds.width + configuration.pageSpacing
        let pagerFrame = CGRect(x: -configuration.pageSpacing / 2, y: 0, width: width, height: bounds.height)
        guard pager.frame != pagerFrame else { return openIfNeeded() }
        isLayingOut = true
        pager.frame = pagerFrame
        pager.contentSize = CGSize(width: width * CGFloat(count), height: bounds.height)
        pager.contentOffset = CGPoint(x: width * CGFloat(index), y: 0)
        for (i, page) in pages { page.frame = pageFrame(i) }
        isLayingOut = false
        updatePages()
        openIfNeeded()

        switch phase {
        case .opening, .restoring: retargetHero()
        case .presented, .dragging, .closing, .closed: break
        }
    }

    private func pageFrame(_ i: Int) -> CGRect {
        CGRect(x: pager.bounds.width * CGFloat(i) + configuration.pageSpacing / 2, y: 0,
               width: pager.bounds.width - configuration.pageSpacing, height: pager.bounds.height)
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
    private func currentImage(_ i: Int) -> UIImage? {
        content(i).still() ?? fallbacks[i]
    }

    private func didLoad(at i: Int) {
        guard let image = currentImage(i) else { return }
        if let page = pages[i] {
            let before = page.image != nil ? page.imageView.layer.contents : nil
            page.setImage(image)
            if let before { crossfade(page.imageView, from: before) }
        }
        if i == index, !hero.isHidden {
            let before = hero.imageView.layer.contents
            hero.imageView.image = image
            crossfade(hero.imageView, from: before)
            retargetHero()
        }
    }

    /// Fades the picture in over the one before: the picture alone, not the content's view on it.
    private func crossfade(_ view: UIView, from before: Any?) {
        let fade = CABasicAnimation(keyPath: "contents")
        fade.fromValue = before
        fade.duration = 0.2
        view.layer.add(fade, forKey: "preview.fade")
    }

    // MARK: Pages

    private func updatePages() {
        guard pager.bounds.width > 0 else { return }
        let position = pager.contentOffset.x / pager.bounds.width
        let visible = Int(floor(position))...Int(ceil(position))
        let wanted = Set((visible.lowerBound - 1...visible.upperBound + 1).filter { (0..<count).contains($0) })
        for (i, page) in pages where !wanted.contains(i) {
            page.removeFromSuperview()
            pages[i] = nil
        }
        for i in wanted where pages[i] == nil {
            let page = PreviewPageView(frame: pageFrame(i))
            page.maximumZoomFactor = configuration.maximumZoomScale
            page.setImage(currentImage(i))
            page.setLiveView(content(i).makeView(for: .page))
            pager.addSubview(page)
            pages[i] = page
        }
        // A page that has scrolled out of sight goes back to fitting the screen.
        for (i, page) in pages where !visible.contains(i) { page.resetZoom() }
    }

    fileprivate func pagerDidScroll() {
        guard !isLayingOut, pager.bounds.width > 0 else { return }
        updatePages()
        let i = Int((pager.contentOffset.x / pager.bounds.width).rounded())
        if (0..<count).contains(i), i != index { setIndex(i) }
    }

    private func setIndex(_ i: Int) {
        guard i != context.index else { return }
        context.index = i
        updateContentState()
        if phase != .closed, phase != .closing { hideSource() }
        onIndexChange?(i)
    }

    private var currentPage: PreviewPageView? { pages[index] }

    // MARK: Sources

    private func hideSource() {
        let source = sourceProvider(index)
        if hiddenSource?.view !== source?.view { hiddenSource?.setHidden(false) }
        source?.setHidden(true)
        hiddenSource = source
    }

    /// The image's shadow as it flies, rising from the thumbnail's (none if the thumbnail isn't on screen).
    private func castShadow(from source: PreviewSource?) {
        guard let source, let state = sourceState(source), state.clip.width > 1, state.clip.height > 1 else { return hero.shadow = nil }
        let dark = (source.view?.traitCollection.userInterfaceStyle ?? .light) == .dark
        hero.shadow = ElevationShadow(image: hero.imageView.image, shape: state.clip.size, corner: source.cornerRadius,
                                    rest: source.elevation, full: fittedFrame.size, dark: dark)
    }

    /// The thumbnail's frame in the viewer, if it is on screen.
    private func visibleFrame(of source: PreviewSource?) -> CGRect? {
        guard let frame = frame(of: source), let root, frame.intersects(root.bounds) else { return nil }
        return frame
    }

    /// The thumbnail's frame in the viewer, on screen or not, while it is in a window.
    private func frame(of source: PreviewSource?) -> CGRect? {
        guard let view = source?.view, view.window != nil, let root, root.window != nil else { return nil }
        let frame = view.convert(view.bounds, to: root)
        return frame.width > 1 && frame.height > 1 ? frame : nil
    }

    /// A picture of the thumbnail as it is on screen, for when there is no image to fly yet.
    private func snapshot(_ source: PreviewSource?) -> UIImage? {
        guard let view = source?.view, let window = view.window else { return nil }
        let rect = view.convert(view.bounds, to: window)
        guard rect.width > 1, rect.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            window.drawHierarchy(in: CGRect(origin: CGPoint(x: -rect.minX, y: -rect.minY), size: window.bounds.size), afterScreenUpdates: false)
        }
    }

    // MARK: Opening and closing

    private var fittedFrame: CGRect {
        guard let root else { return .zero }
        return root.bounds.placing(hero.imageView.image?.size ?? .zero, .fit)
    }

    /// Opens once the stage is in the window and has its size, before that frame is drawn.
    private func openIfNeeded() {
        guard needsOpen, let root, root.window != nil, root.bounds.width > 0 else { return }
        needsOpen = false
        open()
    }

    private func open() {
        let source = sourceProvider(index)
        if currentImage(index) == nil, let snap = snapshot(source) { fallbacks[index] = snap }
        updatePages()
        currentPage?.setImage(currentImage(index))

        let image = currentImage(index)
        showHero(image)
        phase = .opening
        hideSource()

        let fitted = fittedFrame
        castShadow(from: source)
        // The navigation controller shows its bars as it appears; they come in with the image instead.
        navigation?.bars.forEach { $0.alpha = 0 }
        setAccessories(visible: true, delay: 0.06)
        if !UIAccessibility.isReduceMotionEnabled, let view = source?.view, let root {
            let layers = PreviewLayers(thumbnail: view, stage: root)
            self.layers = layers
            if let world = flightWorld(source), let start = sourceState(source, at: world.slotFrame) {
                setHero(start)
                hero.turn = world.world.slot.turn
                fly(.opening(world.world, planned: false)) { [weak self] in self?.didSettlePresented() }
                return planElsewhere(world.world)
            }
            self.layers = nil
        }
        setHero(.vanished(from: fitted))
        animateHero(to: .presented(fitted), spring: configuration.transitionSpring) { [weak self] in
            self?.didSettlePresented()
        }
    }

    private func didSettlePresented() {
        phase = .presented
        currentPage?.setImage(currentImage(index))
        pager.isHidden = false
        hideHero()
        setAccessories(visible: true)
        navigation?.setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    /// Shows the content on screen in the hero: the still, and the content's view over it.
    private func showHero(_ still: UIImage?) {
        hero.imageView.image = still
        hero.setLiveView(content(index).makeView(for: .flight))
        hero.isHidden = false
    }

    /// Taps on the image as it flies home (to open it again), caught at the window: wherever the
    /// image is put among the page's views, a touch on it would go to what holds it, if that even
    /// reaches it. Every other touch, and a pan or scroll begun on the image, goes to the page.
    private lazy var catcher: FlightTapRecognizer = {
        let catcher = FlightTapRecognizer()
        catcher.contains = { [weak self] point in
            guard let self, self.phase == .closing, !self.hero.isHidden, let window = self.root?.window else { return false }
            let clip = self.hero.clipView
            return clip.point(inside: window.convert(point, to: clip), with: nil)
        }
        catcher.onTap = { [weak self] in self?.reopen() }
        return catcher
    }()

    private func catchTaps() {
        guard let window = root?.window else { return }
        catcher.watch(window)
    }

    private func hideHero() {
        endFlight()
        hero.shadow = nil
        hero.isHidden = true
        hero.setLiveView(nil)
    }

    /// Moves the image from the page into the hero, where it can be dragged and flown.
    private func liftHero() {
        guard let root, let page = currentPage else { return }
        let image = page.imageView.convert(page.imageView.bounds, to: root)
        showHero(currentImage(index) ?? page.image)
        castShadow(from: sourceProvider(index))
        setHero(HeroState(image: image, clip: image.intersection(root.bounds), cornerRadius: 0, backdrop: 1))
        pager.isHidden = true
    }

    private func close(velocity: CGPoint) {
        if phase == .presented { liftHero() }
        phase = .closing
        // From here the app has the touches again: the page can be scrolled while the image flies home.
        transitioning.presentation?.passesTouches = true
        navigation?.resignFirstResponder()
        setAccessories(visible: false)
        onDismiss?()

        let source = sourceProvider(index)
        if hiddenSource?.view !== source?.view { hiddenSource?.setHidden(false) }
        hiddenSource = source
        source?.setHidden(true)
        closingSource = source

        if !UIAccessibility.isReduceMotionEnabled, let view = source?.view, let root, visibleFrame(of: source) != nil {
            layers = PreviewLayers(thumbnail: view, stage: root)
            if let world = flightWorld(source) {
                // The finger's velocity as a close without layers keeps it, on the same spring.
                let w = world.world, center = heroState.clip.center, size = heroState.clip.size, backdrop = heroState.backdrop
                let v = PreviewFlight.released(CGVector(dx: velocity.x, dy: velocity.y), from: center, toward: w.slot.center)
                let spring = configuration.transitionSpring
                let omega = 2 * Double.pi / max(spring.response, 0.01), zeta = spring.dampingRatio
                stopSprings()
                flightStart = heroState
                fly(.closing(w, center: center, size: size, velocity: v, backdrop: backdrop, omega: omega, zeta: zeta, planned: false)) { [weak self] in
                    self?.didClose()
                }
                return planElsewhere(w)
            }
            layers = nil
        }
        let target = closedTarget(source)
        animateHero(to: target, spring: configuration.transitionSpring, velocity: velocity) { [weak self] in
            self?.didClose()
        }
        // Flying home to a thumbnail: follow it if the page moves under it.
        if target.backdrop == 0, target.opacity > 0, let frame = visibleFrame(of: source), let springs {
            landing = Landing(frame: frame, springs: springs)
        }
    }

    private func closedTarget(_ source: PreviewSource?) -> HeroState {
        (UIAccessibility.isReduceMotionEnabled ? nil : sourceState(source)) ?? .vanished(from: heroState.image)
    }

    /// The image laid over its thumbnail as the thumbnail draws it, if the thumbnail is on screen.
    private func sourceState(_ source: PreviewSource?, at frame: CGRect? = nil) -> HeroState? {
        guard let source, let frame = frame ?? visibleFrame(of: source), let size = hero.imageView.image?.size else { return nil }
        // A picture of the thumbnail already has its shape: it is drawn whole.
        let mode = hero.imageView.image != nil && hero.imageView.image === fallbacks[index] ? PreviewContentMode.fit : source.contentMode
        return .source(frame: frame, imageSize: size, mode: mode, cornerRadius: source.cornerRadius)
    }

    private func didClose() {
        phase = .closed
        closingSource?.setHidden(false)
        hiddenSource = nil
        landing = nil
        contents.values.forEach { $0.cancel() }
        onDidDismiss?()
        handOverOrFinish()
    }

    /// The image is home: the page, empty and letting every touch through, is dismissed.
    private func finish() {
        handoff = nil
        hideHero()
        backdrop.alpha = 0
        closingSource = nil
        retire()
    }

    private func retire() {
        ticker.stop()
        handoff = nil
        navigation?.presentingViewController?.dismiss(animated: false)
        navigation = nil
        isPresented = false
        Self.retained[ObjectIdentifier(self)] = nil
    }

    /// The target of the running animation, worked out again (the image or the screen changed size).
    private func retargetHero() {
        guard springs != nil else { return }
        switch phase {
        case .opening, .restoring:
            springs?.retarget(HeroState.presented(fittedFrame).vector)
        case .closing:
            springs?.retarget(closedTarget(closingSource).vector)
        case .presented, .dragging, .closed:
            break
        }
        ticker.start()
    }

    // MARK: Dragging

    private func dismissAxis(for velocity: CGPoint) -> DismissDrag.Axis? {
        DismissDrag.axis(for: velocity, index: index, count: count)
    }

    fileprivate func canBeginDrag(velocity: CGPoint) -> Bool {
        guard let axis = dismissAxis(for: velocity) else { return false }
        dragAxis = axis
        switch phase {
        case .opening, .restoring:
            return true
        case .presented:
            guard let page = currentPage, !page.isZoomed else { return false }
            return !pager.isDragging && !pager.isDecelerating
        case .dragging, .closing, .closed:
            return false
        }
    }

    fileprivate func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let root else { return }
        switch pan.state {
        case .began:
            if phase == .presented { liftHero() }
            stopSprings()
            endFlight()
            phase = .dragging
            drag = DismissDrag(start: heroState, anchor: pan.location(in: root), axis: dragAxis, container: root.bounds.size)
            setAccessories(visible: false)
        case .changed:
            guard let drag else { return }
            setHero(drag.state(translation: pan.translation(in: root)))
        case .ended, .cancelled, .failed:
            guard let drag else { return }
            self.drag = nil
            let t = pan.translation(in: root), v = pan.velocity(in: root)
            if pan.state == .ended, drag.closes(translation: t, velocity: v) {
                close(velocity: v)
            } else {
                phase = .restoring
                animateHero(to: .presented(fittedFrame), spring: configuration.restoreSpring, velocity: v) { [weak self] in
                    self?.didSettlePresented()
                }
            }
        default:
            break
        }
    }

    fileprivate func handleTap(_ tap: UITapGestureRecognizer) {
        guard phase == .presented else { return }
        if configuration.tapTogglesAccessories {
            context.accessoriesVisible.toggle()
            setAccessories(visible: true)
            navigation?.setNeedsUpdateOfHomeIndicatorAutoHidden()
        } else {
            dismiss()
        }
    }

    fileprivate func handleDoubleTap(_ tap: UITapGestureRecognizer) {
        guard phase == .presented, let page = currentPage else { return }
        page.toggleZoom(at: tap.location(in: page))
    }

    // MARK: Accessories

    /// Shows or hides the navigation bar and toolbar, fading them where they are.
    private func setAccessories(visible: Bool, delay: TimeInterval = 0) {
        guard let navigation else { return }
        barsAlpha = visible && context.accessoriesVisible ? 1 : 0
        let bars = navigation.bars
        guard bars.contains(where: { $0.alpha != barsAlpha }) else { return }
        UIView.animate(withDuration: barsAlpha > 0 ? 0.25 : 0.15, delay: delay, options: [.beginFromCurrentState, .allowUserInteraction]) {
            bars.forEach { $0.alpha = self.barsAlpha }
        }
    }

    fileprivate var hidesHomeIndicator: Bool { !statusBarFollowsApp && !context.accessoriesVisible }

    #if !os(visionOS)
    /// Light over the backdrop; while closing, whatever the app underneath asks for.
    fileprivate var statusBarStyle: UIStatusBarStyle {
        guard statusBarFollowsApp, let app = appStatusBarController(\.childForStatusBarStyle) else { return .lightContent }
        return app.preferredStatusBarStyle
    }

    fileprivate var statusBarHidden: Bool {
        guard statusBarFollowsApp, let app = appStatusBarController(\.childForStatusBarHidden) else { return false }
        return app.prefersStatusBarHidden
    }

    /// The view controller under the viewer that decides the status bar, the way UIKit finds it.
    private func appStatusBarController(_ child: KeyPath<UIViewController, UIViewController?>) -> UIViewController? {
        var controller = navigation?.presentingViewController?.view.window?.rootViewController
        while let current = controller {
            if let presented = current.presentedViewController, presented !== navigation, !presented.isBeingDismissed,
               presented.modalPresentationCapturesStatusBarAppearance || presented.modalPresentationStyle == .fullScreen {
                controller = presented
            } else if let next = current[keyPath: child] {
                controller = next
            } else {
                return current
            }
        }
        return nil
    }
    #endif

    // MARK: Hero animation

    private func setHero(_ state: HeroState) {
        heroState = state
        hero.apply(state)
        backdrop.alpha = state.backdrop
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
        ticker.start()
    }

    private func stopSprings() {
        ticker.stop()
        springs = nil
        springDone = nil
    }

    private func tick(_ dt: Double) {
        if let handoff { return handOver(handoff) }
        if flight != nil { return stepFlight(dt) }
        guard var springs else { return ticker.stop() }
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
        backdrop.alpha = heroState.backdrop
        followAppStatusBarIfShowing()
        if done {
            let completion = springDone
            stopSprings()
            completion?()
        }
    }

    // MARK: Flight among the layers

    /// The page as the flight sees it now: the thumbnail (and its frame unturned, for its state),
    /// the layers over it, the image fitted full screen.
    private func flightWorld(_ source: PreviewSource?) -> (world: FlightWorld, slotFrame: CGRect)? {
        guard let root, let view = source?.view, let turned = PreviewLayers.turnedFrame(of: view, in: root) else { return nil }
        let frame = CGRect(x: turned.center.x - turned.size.width / 2, y: turned.center.y - turned.size.height / 2,
                           width: turned.size.width, height: turned.size.height)
        guard let state = sourceState(source, at: frame) else { return nil }
        let slot = TurnedRect(center: turned.center, size: state.clip.size, turn: turned.turn)
        let world = FlightWorld(slot: slot, covers: layers?.shapes() ?? [], paged: layers?.paged ?? [],
                                fitted: fittedFrame, bounds: root.bounds)
        return (world, frame)
    }

    private func fly(_ flight: PreviewFlight, completion: @escaping () -> Void) {
        flightSerial += 1
        pendingPlan = nil
        self.flight = flight
        flightDone = completion
        stepFlight(0)
        ticker.start()
    }

    private func stepFlight(_ dt: Double) {
        guard var flight else { return }
        let source = flight.kind == .opening ? hiddenSource : closingSource
        guard let now = flightWorld(source) else {
            // The thumbnail went (its cell was reused): on with the springs, over everything.
            let done = flightDone
            endFlight()
            if flight.kind == .opening {
                animateHero(to: .presented(fittedFrame), spring: configuration.transitionSpring) { done?() }
            } else {
                animateHero(to: closedTarget(source), spring: configuration.transitionSpring) { done?() }
            }
            return
        }
        if dt > 0, var planned = pendingPlan, flight.clock + dt >= planned.clock {
            // Where the plan was made for: the planned flight from here on.
            pendingPlan = nil
            planned.advance(flight.clock + dt - planned.clock, world: now.world)
            flight = planned
        } else if dt > 0 {
            flight.advance(dt, world: now.world)
        }
        self.flight = flight
        let clip = flight.clip(now.world), g = CGFloat(flight.progress)
        guard let slotState = sourceState(source, at: now.slotFrame) else { return }
        var state: HeroState
        switch flight.kind {
        case .opening: state = slotState.mixed(with: .presented(fittedFrame), g)
        case .closing: state = (flightStart ?? slotState).mixed(with: slotState, g)
        }
        state = state.centred(at: clip.center)
        state.backdrop = flight.backdrop
        heroState = state
        hero.turn = clip.turn
        hero.apply(state)
        backdrop.alpha = state.backdrop
        layers?.host(hero, level: flight.level)
        if flight.kind == .closing { catchTaps() } else { catcher.stopWatching() }
        if flight.kind == .closing { followAppStatusBarIfShowing() }
        if flight.isDone {
            let done = flightDone
            self.flight = nil
            flightDone = nil
            if flight.kind == .opening { endFlight() }
            ticker.stop()
            done?()
        }
    }

    /// The flight's way among the layers is chosen off the main thread (rehearsing it ahead takes
    /// a while, long in a debug build), for where the image will be by the time it's ready; the
    /// image flies on unplanned till then (opening: still where it is; closing: straight home)
    /// and the planned flight takes its place as it gets there, the same flight up to that moment.
    private func planElsewhere(_ world: FlightWorld) {
        guard let flight else { return }
        let serial = flightSerial
        let ahead = max(1.0 / 30, Self.planCost * 1.5 + 1.0 / 60)
        Task.detached(priority: .userInitiated) {
            let start = Date()
            let planned = flight.plannedAhead(by: ahead, world: world)
            let cost = Date().timeIntervalSince(start)
            await MainActor.run { [weak self] in
                Self.planCost = cost
                self?.adopt(planned, for: serial)
            }
        }
    }

    /// How long the last plan took to choose.
    private static var planCost = 0.06
    /// A plan come before the flight got where it was made for.
    private var pendingPlan: PreviewFlight?

    private func adopt(_ planned: PreviewFlight, for serial: Int) {
        guard serial == flightSerial, var flight, !flight.isDone else { return }
        if flight.clock <= planned.clock {
            pendingPlan = planned
            return
        }
        // Late: its plan, eased in from here.
        let source = flight.kind == .opening ? hiddenSource : closingSource
        guard let now = flightWorld(source) else { return }
        flight.adoptPlan(of: planned, world: now.world)
        self.flight = flight
    }

    /// The image flying home tapped: it turns back and opens again from where it is.
    fileprivate func reopen() {
        guard phase == .closing, let flight, flight.kind == .closing, let source = closingSource, let world = flightWorld(source) else { return }
        let clip = flight.clip(world.world)
        let from = (center: clip.center, size: clip.size, velocity: flight.velocity, level: flight.level)
        phase = .opening
        transitioning.presentation?.passesTouches = false
        landing = nil
        hiddenSource = source
        closingSource = nil
        flightStart = nil
        if statusBarFollowsApp {
            statusBarFollowsApp = false
            #if !os(visionOS)
            UIView.animate(withDuration: 0.2) { self.navigation?.setNeedsStatusBarAppearanceUpdate() }
            #endif
        }
        setAccessories(visible: true, delay: 0.06)
        onIndexChange?(index)
        fly(.opening(world.world, from: from, planned: false)) { [weak self] in self?.didSettlePresented() }
        planElsewhere(world.world)
    }

    /// Another viewer opens: this one's image, still flying home, lands at once.
    private func landNow() {
        if phase == .closing {
            flight = nil
            flightDone = nil
            stopSprings()
            phase = .closed
            closingSource?.setHidden(false)
            hiddenSource = nil
            landing = nil
            contents.values.forEach { $0.cancel() }
            onDidDismiss?()
        }
        finish()
    }

    /// Back on the stage, flat, no flight.
    private func endFlight() {
        flight = nil
        flightDone = nil
        flightStart = nil
        layers = nil
        catcher.stopWatching()
        hero.turn = 0
        if let root, hero.superview !== root {
            hero.layer.zPosition = 0
            hero.transform = .identity
            root.addSubview(hero)
            hero.frame = root.bounds
        }
    }

    /// Closing: the status bar turns back to the app's as the page shows through.
    private func followAppStatusBarIfShowing() {
        guard phase == .closing, !statusBarFollowsApp, heroState.backdrop < 0.5 else { return }
        statusBarFollowsApp = true
        #if !os(visionOS)
        UIView.animate(withDuration: 0.2) { self.navigation?.setNeedsStatusBarAppearanceUpdate() }
        #endif
    }

    // MARK: Hand-over

    /// The thumbnail shows again a frame or two after it is told to (SwiftUI may take one more).
    /// Until it surely has, the landed image stays pinned on it, following it if the page is
    /// scrolling, so the two never part; then the image goes.
    private func handOverOrFinish() {
        guard heroState.opacity > 0, closingSource != nil else { return finish() }
        handoff = 4
        ticker.start()
    }

    private func handOver(_ frames: Int) {
        if let world = flightWorld(closingSource), let state = sourceState(closingSource, at: world.slotFrame) {
            setHero(state)
            hero.turn = world.world.slot.turn
            layers?.host(hero, level: 0)
        } else if let frame = frame(of: closingSource), let state = sourceState(closingSource, at: frame) {
            setHero(state)
        }
        if frames > 1 { handoff = frames - 1 } else { finish() }
    }

    // MARK: Keyboard

    fileprivate func handleKey(_ command: UIKeyCommand) {
        switch command.input {
        case UIKeyCommand.inputEscape: dismiss()
        case UIKeyCommand.inputLeftArrow: select(index - 1, animated: true)
        case UIKeyCommand.inputRightArrow: select(index + 1, animated: true)
        default: break
        }
    }

    // MARK: Gesture plumbing

    @MainActor private final class GestureTarget: NSObject {
        weak var controller: ImagePreviewController?
        init(_ controller: ImagePreviewController) { self.controller = controller }
        @objc func pan(_ g: UIPanGestureRecognizer) { controller?.handlePan(g) }
        @objc func tap(_ g: UITapGestureRecognizer) { controller?.handleTap(g) }
        @objc func doubleTap(_ g: UITapGestureRecognizer) { controller?.handleDoubleTap(g) }
    }

    @MainActor private final class GestureDelegate: NSObject, UIGestureRecognizerDelegate, UIScrollViewDelegate {
        weak var controller: ImagePreviewController?
        init(_ controller: ImagePreviewController) { self.controller = controller }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let controller, let pan = g as? UIPanGestureRecognizer, pan === controller.dismissPan else { return true }
            // A swipe's first scroll can come with no speed yet: its way so far then.
            var velocity = pan.velocity(in: pan.view)
            if velocity == .zero { velocity = pan.translation(in: pan.view) }
            return controller.canBeginDrag(velocity: velocity)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { controller?.pagerDidScroll() }
    }
}

// MARK: - Views

/// The page's content: the backdrop, the images and the image in flight.
final class PreviewStageViewController: UIViewController {
    private weak var controller: ImagePreviewController?

    init(controller: ImagePreviewController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = StageView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        controller?.load(into: view)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        controller?.layout(in: view)
    }

    override func setToolbarItems(_ items: [UIBarButtonItem]?, animated: Bool) {
        super.setToolbarItems(items, animated: animated)
        (navigationController as? PreviewNavigationController)?.updateToolbar()
    }

    /// Lays out again when it is put in a window, where the viewer can open.
    private final class StageView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { setNeedsLayout() }
        }
    }
}

/// The presented navigation controller: speaks for the viewer to the system (status bar, keys, VoiceOver).
final class PreviewNavigationController: UINavigationController {
    private weak var controller: ImagePreviewController?

    init(controller: ImagePreviewController, page: UIViewController) {
        self.controller = controller
        super.init(rootViewController: page)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
        // Light bars with nothing behind them, over the dark backdrop.
        overrideUserInterfaceStyle = .dark
        let bar = UINavigationBarAppearance()
        bar.configureWithTransparentBackground()
        navigationBar.standardAppearance = bar
        navigationBar.scrollEdgeAppearance = bar
        navigationBar.compactAppearance = bar
        let toolbarAppearance = UIToolbarAppearance()
        toolbarAppearance.configureWithTransparentBackground()
        toolbar.standardAppearance = toolbarAppearance
        toolbar.scrollEdgeAppearance = toolbarAppearance
        toolbar.compactAppearance = toolbarAppearance
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateToolbar()
    }

    /// The toolbar shows when the page has something to put on it.
    func updateToolbar() {
        let hidden = topViewController?.toolbarItems?.isEmpty ?? true
        guard isToolbarHidden != hidden else { return }
        setToolbarHidden(hidden, animated: false)
        view.layoutIfNeeded()
        bars.forEach { $0.alpha = controller?.barsAlpha ?? 0 }
    }

    /// The navigation bar and the toolbar, however the system draws them: everything but the page.
    var bars: [UIView] {
        guard let page = topViewController?.viewIfLoaded else { return [] }
        return view.subviews.filter { !page.isDescendant(of: $0) }
    }

    override func accessibilityPerformEscape() -> Bool {
        controller?.dismiss()
        return true
    }

    #if !os(visionOS)
    override var childForStatusBarStyle: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }
    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
    override var preferredStatusBarStyle: UIStatusBarStyle { controller?.statusBarStyle ?? .lightContent }
    override var prefersStatusBarHidden: Bool { controller?.statusBarHidden ?? false }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var prefersHomeIndicatorAutoHidden: Bool { controller?.hidesHomeIndicator ?? false }
    #endif

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand.inputEscape, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow].map {
            let command = UIKeyCommand(input: $0, modifierFlags: [], action: #selector(key(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func key(_ command: UIKeyCommand) { controller?.handleKey(command) }
}

/// Presents the viewer over everything, leaving what is underneath in place.
private final class PreviewTransitioning: NSObject, UIViewControllerTransitioningDelegate {
    private(set) weak var presentation: PreviewPresentationController?

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        let presentation = PreviewPresentationController(presentedViewController: presented, presenting: presenting)
        self.presentation = presentation
        return presentation
    }
}

private final class PreviewPresentationController: UIPresentationController {
    /// Closing: touches go to what is underneath, which can be scrolled while the image flies home.
    var passesTouches = false {
        didSet { containerView?.isUserInteractionEnabled = !passesTouches }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        presentedView?.frame = frameOfPresentedViewInContainerView
    }
}

/// Swipes between the images.
private final class PreviewPagerView: UIScrollView {
    var shouldBeginPan: (CGPoint) -> Bool = { _ in true }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === panGestureRecognizer, !shouldBeginPan(panGestureRecognizer.velocity(in: self)) { return false }
        return super.gestureRecognizerShouldBegin(g)
    }
}

/// The moving image: a clipping frame with rounded corners, the whole image inside it.
private final class HeroView: UIView {
    let clipView = UIView()
    let imageView = UIImageView()
    /// Its shadow's layers, under the clip.
    private let shade = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipView.clipsToBounds = true
        clipView.layer.cornerCurve = .continuous
        imageView.contentMode = .scaleToFill
        imageView.accessibilityIgnoresInvertColors = true
        clipView.addSubview(imageView)
        shade.isUserInteractionEnabled = false
        addSubview(shade)
        addSubview(clipView)

        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Never in the way of a touch: it lies over the whole page (a tap on the image flying home
    /// is caught at the window, `FlightTapRecognizer`).
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    private var liveView: UIView?

    /// The content's view, over the still.
    func setLiveView(_ view: UIView?) {
        liveView?.removeFromSuperview()
        liveView = view
        guard let view else { return }
        view.frame = imageView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.addSubview(view)
    }

    /// How it's turned (a thumbnail lying at an angle), about the clip's centre.
    var turn: CGFloat = 0

    /// Its shadow, by its height (its size), as much as the page shows.
    var shadow: ElevationShadow? {
        didSet {
            oldValue?.layers.forEach { $0.removeFromSuperlayer() }
            shadow?.layers.forEach { shade.layer.addSublayer($0) }
        }
    }

    func apply(_ state: HeroState) {
        clipView.transform = .identity
        clipView.bounds = CGRect(origin: .zero, size: state.clip.size)
        clipView.center = CGPoint(x: state.clip.midX, y: state.clip.midY)
        clipView.transform = turn == 0 ? .identity : CGAffineTransform(rotationAngle: turn)
        clipView.layer.cornerRadius = min(state.cornerRadius, min(state.clip.width, state.clip.height) / 2)
        imageView.frame = state.image.offsetBy(dx: -state.clip.minX, dy: -state.clip.minY)
        clipView.alpha = state.opacity
        shade.frame = bounds
        shadow?.apply(center: CGPoint(x: state.clip.midX, y: state.clip.midY), size: state.clip.size, turn: turn,
                      seen: (1 - state.backdrop) * state.opacity)
    }
}

extension UIScrollView {
    /// No blur or dimming where the bars cover the content: the images go under the bars as they are.
    func hidesEdgeEffects() {
        if #available(iOS 26.0, visionOS 26.0, *) {
            for effect in [topEdgeEffect, bottomEdgeEffect, leftEdgeEffect, rightEdgeEffect] { effect.isHidden = true }
        }
    }
}

extension UIView {
    /// The view controller this view belongs to.
    var closestViewController: UIViewController? {
        var responder = next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}
#endif
