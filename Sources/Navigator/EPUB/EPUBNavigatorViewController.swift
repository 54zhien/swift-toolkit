//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumInternal
import ReadiumShared
import SafariServices
import SwiftSoup
import UIKit
import WebKit

private final class PageSurfaceOneShot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var finished = false
    private var pendingValue: Value?
    private var hasPendingValue = false
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        var value: Value?
        var shouldResume = false
        var hasValue = false
        lock.lock()
        if finished {
            value = pendingValue
            shouldResume = true
            hasValue = hasPendingValue
        } else {
            self.continuation = continuation
        }
        lock.unlock()
        if shouldResume, hasValue {
            continuation.resume(returning: value!)
        }
    }

    func attachTimeout(_ task: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask = task
            lock.unlock()
        }
    }

    func resume(_ value: Value) {
        var continuation: CheckedContinuation<Value, Never>?
        var timeoutTask: Task<Void, Never>?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        if let waiting = self.continuation {
            continuation = waiting
        } else {
            pendingValue = value
            hasPendingValue = true
        }
        timeoutTask = self.timeoutTask
        lock.unlock()
        timeoutTask?.cancel()
        continuation?.resume(returning: value)
    }
}

/// A native paint barrier. Unlike evaluating a JavaScript Promise, this waits
/// for two actual display-link callbacks from the host screen before a WebKit
/// snapshot is requested.
@MainActor private final class TwoFramePaintBarrier {
    private let gate = PageSurfaceOneShot<Bool>()
    private var displayLink: CADisplayLink?
    private var target: DisplayLinkTarget?
    private var remainingFrames = 2
    private var finished = false

    func start(
        _ continuation: CheckedContinuation<Bool, Never>,
        deadline: UInt64 = DispatchTime.now().uptimeNanoseconds + 750_000_000
    ) {
        gate.install(continuation)
        guard !finished else { return }

        let target = DisplayLinkTarget { [weak self] in
            self?.didDisplayFrame()
        }
        self.target = target
        let displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)

        let timeoutTask = Task { @MainActor [weak self] in
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else {
                self?.finish(false)
                return
            }
            try? await Task.sleep(nanoseconds: deadline - now)
            self?.finish(false)
        }
        gate.attachTimeout(timeoutTask)
    }

    func cancel() {
        finish(false)
    }

    private func didDisplayFrame() {
        remainingFrames -= 1
        if remainingFrames <= 0 {
            finish(true)
        }
    }

    private func finish(_ value: Bool) {
        guard !finished else { return }
        finished = true
        displayLink?.invalidate()
        displayLink = nil
        target = nil
        gate.resume(value)
    }

    private final class DisplayLinkTarget: NSObject {
        let callback: () -> Void

        init(callback: @escaping () -> Void) {
            self.callback = callback
        }

        @objc func tick(_ displayLink: CADisplayLink) {
            callback()
        }
    }
}

@MainActor public protocol EPUBNavigatorDelegate: VisualNavigatorDelegate, SelectableNavigatorDelegate,
    ViewportObservingNavigatorDelegate
{
    // MARK: - WebView Customization

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController)
}

public extension EPUBNavigatorDelegate {
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {}
}

public typealias EPUBContentInsets = (top: CGFloat, bottom: CGFloat)

open class EPUBNavigatorViewController: InputObservableViewController,
    VisualNavigator, ViewportObservingNavigator, SelectableNavigator,
    DecorableNavigator, Configurable, Loggable, AdjacentPageSurfaceProviding
{
    public enum EPUBError: Error {
        /// The provided publication is restricted. Check that any DRM was
        /// properly unlocked using a Content Protection.
        case publicationRestricted

        /// Returned when calling evaluateJavaScript() before a resource is
        /// loaded.
        case spreadNotLoaded

        /// Failed to serve the publication or assets with the provided HTTP
        /// server.
        @available(*, deprecated, message: "The HTTP server is no longer needed for the EPUB navigator.")
        case serverFailure(Error)
    }

    public struct Configuration {
        /// Initial set of setting preferences.
        public var preferences: EPUBPreferences

        /// Provides default fallback values and ranges for the user settings.
        public var defaults: EPUBDefaults

        /// Editing actions which will be displayed in the default text selection menu.
        ///
        /// The default set of editing actions is `EditingAction.defaultActions`.
        ///
        /// You can provide custom actions with `EditingAction(title: "Highlight", action: #selector(highlight:))`.
        /// Then, implement the selector in one of your classes in the responder chain. Typically, in the
        /// `UIViewController` wrapping the `EPUBNavigatorViewController`.
        public var editingActions: [EditingAction]

        /// Disables horizontal page turning when scroll is enabled.
        public var disablePageTurnsWhileScrolling: Bool

        /// Enables a publication-wide vertical scroll for reflowable EPUBs
        /// when the `scroll` preference is enabled. Fixed-layout EPUBs and
        /// existing paginated configurations keep their current behavior.
        public var continuousScroll: Bool

        /// Content insets used to add some vertical margins around reflowable
        /// EPUB publications. Note that the margins include the safe area
        /// insets. To avoid any "jump" when toggling the status bar, provide
        /// values large enough.
        ///
        /// The insets can be configured for each size class to allow smaller
        /// margins on compact screens.
        ///
        /// For more control, implement the `navigatorContentInset()` delegate
        /// method, which takes precedence over this configuration property
        /// when implemented.
        public var contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets]

        /// Number of positions (as in `Publication.positionList`) to preload before the current page.
        public var preloadPreviousPositionCount: Int

        /// Number of positions (as in `Publication.positionList`) to preload after the current page.
        public var preloadNextPositionCount: Int

        /// Supported HTML decoration templates.
        public var decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate]

        /// Additional font families which will be available in the preferences.
        public var fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration]

        /// Readium CSS reading system settings.
        ///
        /// See https://readium.org/readium-css/docs/CSS19-api.html#reading-system-styles
        public var readiumCSSRSProperties: CSSRSProperties

        /// Logs the state changes when true.
        public var debugState: Bool

        public init(
            preferences: EPUBPreferences = .empty,
            defaults: EPUBDefaults = EPUBDefaults(),
            editingActions: [EditingAction] = EditingAction.defaultActions,
            disablePageTurnsWhileScrolling: Bool = false,
            continuousScroll: Bool = false,
            contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets] = [
                .compact: (top: 34, bottom: 34),
                .regular: (top: 62, bottom: 62),
            ],
            preloadPreviousPositionCount: Int = 2,
            preloadNextPositionCount: Int = 6,
            decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate] = HTMLDecorationTemplate.defaultTemplates(),
            fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration] = [],
            readiumCSSRSProperties: CSSRSProperties = CSSRSProperties(),
            debugState: Bool = false
        ) {
            self.preferences = preferences
            self.defaults = defaults
            self.editingActions = editingActions
            self.disablePageTurnsWhileScrolling = disablePageTurnsWhileScrolling
            self.continuousScroll = continuousScroll
            self.contentInset = contentInset
            self.preloadPreviousPositionCount = preloadPreviousPositionCount
            self.preloadNextPositionCount = preloadNextPositionCount
            self.decorationTemplates = decorationTemplates
            self.fontFamilyDeclarations = fontFamilyDeclarations
            self.readiumCSSRSProperties = readiumCSSRSProperties
            self.debugState = debugState
        }

        func contentInset(for sizeClass: UIUserInterfaceSizeClass) -> EPUBContentInsets {
            contentInset[sizeClass]
                ?? contentInset[.regular]
                ?? contentInset[.unspecified]
                ?? (top: 0, bottom: 0)
        }
    }

    public weak var delegate: EPUBNavigatorDelegate?

    /// Information about the visible portion of the publication, when rendered.
    public private(set) var viewport: NavigatorViewport? {
        didSet {
            if oldValue != viewport {
                delegate?.navigator(self, viewportDidChange: viewport)
            }
        }
    }

    @available(*, deprecated, renamed: "NavigatorViewport")
    public typealias Viewport = NavigatorViewport

    /// Navigation state.
    private enum State: Equatable {
        /// Initializing the navigator.
        case initializing
        /// Loading the spreads at the `pendingLocator`, for example after
        /// changing the user settings, rotating the screen or loading the
        /// publication.
        case loading(pendingLocator: Locator?)
        /// Waiting for further navigation instructions.
        case idle
        /// Jumping to `pendingLocator`.
        case jumping(pendingLocator: Locator)
        /// Turning the page in the given `direction`.
        case moving(direction: EPUBSpreadView.Direction)

        var pendingLocator: Locator? {
            switch self {
            case let .loading(pendingLocator: locator):
                return locator
            case let .jumping(pendingLocator: locator):
                return locator
            default:
                return nil
            }
        }

        mutating func transition(_ event: Event) -> Bool {
            switch (self, event) {
            // Loading the spreads is always possible, because it can be triggered by rotating the
            // screen. In which case it cancels any on-going state.
            case let (_, .load(locator)):
                self = .loading(pendingLocator: locator)

            // All events are ignored when loading spreads, except for `loaded` and `load`.
            case (.loading, .loaded):
                self = .idle

            case (.loading, _):
                return false

            case let (.idle, .jump(locator)):
                self = .jumping(pendingLocator: locator)

            case let (.idle, .move(direction)):
                self = .moving(direction: direction)

            case (.jumping, .jumped):
                self = .idle

            // Moving or jumping to another locator is not allowed during a pending jump.
            case (.jumping, .jump),
                 (.jumping, .move):
                return false

            case (.moving, .moved):
                self = .idle

            // Moving or jumping to another locator is not allowed during a pending move.
            case (.moving, .jump),
                 (.moving, .move):
                return false

            default:
                log(.error, "Invalid event \(event) for state \(self)")
                return false
            }

            return true
        }
    }

    /// Navigation event.
    private enum Event: Equatable {
        /// Load the spreads at the given locator, for example after changing
        /// the user settings, rotating the screen or loading the publication.
        case load(Locator?)
        /// The spreads were loaded.
        case loaded
        /// Jump to the given locator.
        case jump(Locator)
        /// Finished jumping to a locator.
        case jumped
        /// Turn the page in the given direction.
        case move(EPUBSpreadView.Direction)
        /// Finished turning the page.
        case moved
    }

    /// Current navigation state.
    private var state: State = .initializing {
        didSet {
            if config.debugState {
                log(.debug, "* \(state)")
            }

            // Disable user interaction while transitioning, to avoid UX issues.
            switch state {
            case .initializing, .loading, .jumping, .moving:
                paginationView?.isUserInteractionEnabled = false
            case .idle:
                paginationView?.isUserInteractionEnabled = isUserPageTurnInteractionEnabled
            }
        }
    }

    private let readingOrder: [Link]
    public private(set) var currentLocation: Locator?
    private let loadPositionsByReadingOrder: () async -> ReadResult<[[Locator]]>
    private var positionsByReadingOrder: [[Locator]] = []

    private let viewModel: EPUBNavigatorViewModel
    public var publication: Publication {
        viewModel.publication
    }

    /// Prepared surfaces are generated while the navigator is settled. The
    /// interactive transition only takes one out of this cache; it never
    /// navigates the live WebView or captures a snapshot.
    private var adjacentPageGeneration = 0
    private let adjacentPageProgressionTolerance = 0.01
    private enum AdjacentPageTransactionPhase: Equatable {
        case prepared
        case committing
    }
    private struct AdjacentPageTransaction {
        let surface: NavigatorPageSurface
        var phase: AdjacentPageTransactionPhase
        var cancelRequested = false
        var externalNavigationRequested = false
    }
    private var adjacentPageTransaction: AdjacentPageTransaction?
    private var adjacentPageCache: [NavigatorPageDirection: NavigatorPageSurface] = [:]
    private var preparedCurrentPageSurfaceCache: NavigatorCurrentPageSurface?
    private var adjacentPageReadiness: [NavigatorPageDirection: NavigatorPageSurfaceReadiness] = [
        .backward: .unknown,
        .forward: .unknown,
    ]
    private var adjacentPagePrewarmToken: UUID?
    private var suppressLocationNotifications = false
    private var isPerformingAdjacentPageNavigation = false
    private var continuousPageRemeasureTask: Task<Void, Never>?
    private var continuousPageRemeasureToken: UUID?
    private var continuousPageRemeasureGeneration = 0
    private var pendingContinuousPageRemeasureSpreads: [ObjectIdentifier: EPUBSpreadView] = [:]

    /// Enables the navigator's built-in horizontal page-turn gestures.
    /// Clients rendering their own interactive transitions can disable this
    /// while retaining programmatic navigation and text interaction.
    public var isUserPageTurnInteractionEnabled = true {
        didSet {
            guard oldValue != isUserPageTurnInteractionEnabled else { return }
            updatePageTurnInteraction()
        }
    }

    /// Resolved direction after applying publication metadata and preferences.
    public var pageReadingProgression: ReadingProgression {
        viewModel.readingProgression
    }

    var config: Configuration {
        viewModel.config
    }

    /// Creates a new instance of `EPUBNavigatorViewController`.
    ///
    /// - Parameters:
    ///   - publication: EPUB publication to render.
    ///   - initialLocation: Starting location in the publication, defaults to
    ///   the beginning.
    ///   - readingOrder: Custom order of resources to display. Used for example
    ///   to display a non-linear resource on its own.
    ///   - config: Additional navigator configuration.
    public convenience init(
        publication: Publication,
        initialLocation: Locator?,
        readingOrder: [Link]? = nil,
        config: Configuration = .init()
    ) throws {
        precondition(readingOrder.map { !$0.isEmpty } ?? true)

        guard !publication.isRestricted else {
            throw EPUBError.publicationRestricted
        }

        let viewModel = EPUBNavigatorViewModel(
            publication: publication,
            readingOrder: readingOrder ?? publication.readingOrder,
            config: config
        )

        self.init(
            viewModel: viewModel,
            initialLocation: initialLocation,
            readingOrder: viewModel.readingOrder,
            positionsByReadingOrder:
            // Positions and total progression only make sense in the context
            // of the publication's actual reading order. Therefore when
            // provided with a different reading order, we should assume the
            // positions list is empty, and also not compute the
            // totalProgression when calculating the current locator.
            (readingOrder != nil) ? { .success([]) } : publication.positionsByReadingOrder
        )
    }

    /// Creates a new instance of `EPUBNavigatorViewController`.
    @available(*, deprecated, message: "The HTTP server is no longer needed for the EPUB navigator.")
    public convenience init(
        publication: Publication,
        initialLocation: Locator?,
        readingOrder: [Link]? = nil,
        config: Configuration = .init(),
        httpServer: HTTPServer
    ) throws {
        try self.init(
            publication: publication,
            initialLocation: initialLocation,
            readingOrder: readingOrder,
            config: config
        )
    }

    private init(
        viewModel: EPUBNavigatorViewModel,
        initialLocation: Locator?,
        readingOrder: [Link],
        positionsByReadingOrder: @escaping () async -> ReadResult<[[Locator]]>
    ) {
        self.viewModel = viewModel
        currentLocation = initialLocation
        self.readingOrder = readingOrder
        loadPositionsByReadingOrder = positionsByReadingOrder

        super.init(nibName: nil, bundle: nil)

        viewModel.delegate = self
        viewModel.editingActions.delegate = self

        setupLegacyInputCallbacks(
            onTap: { [weak self] point in
                guard let self else { return }
                self.delegate?.navigator(self, didTapAt: point)
            },
            onPressKey: { [weak self] event in
                guard let self else { return }
                self.delegate?.navigator(self, didPressKey: event)
            },
            onReleaseKey: { [weak self] event in
                guard let self else { return }
                self.delegate?.navigator(self, didReleaseKey: event)
            }
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override open func viewDidLoad() {
        super.viewDidLoad()

        // Will call `accessibilityScroll()` when VoiceOver reaches the end of
        // the current resource. We can use this to go to the next resource.
        view.accessibilityTraits.insert(.causesPageTurn)

        Task {
            await initialize()
        }
    }

    private var isActive = true

    @objc private func willResignActive() {
        isActive = false
    }

    @objc private func didBecomeActive() {
        isActive = true

        // The device may have rotated since the last time the app was active.
        // We may need to refresh the spreads in this situation. Unfortunately,
        // the `viewWillTransition(to:with:)` API is called before we receive
        // the `didBecomeActive` notification, so we cannot rely on it here.
        viewModel.viewSizeWillChange(view.bounds.size)

        if needsReloadSpreadsOnActive {
            needsReloadSpreadsOnActive = false
            reloadSpreads()
        }
    }

    private func initialize() async {
        do {
            positionsByReadingOrder = try await loadPositionsByReadingOrder().get()
        } catch {
            log(.error, DebugError("Failed to load positions.", cause: error))
        }

        paginationView = makePaginationView(
            hasPositions: !positionsByReadingOrder.isEmpty
        )

        paginationView!.frame = view.bounds
        paginationView!.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        view.addSubview(paginationView!)

        applySettings()

        _reloadSpreads()

        onInitializedCallbacks.complete()
    }

    private let onInitializedCallbacks = CompletionList()

    private func initialized() async {
        await withCheckedContinuation { continuation in
            whenInitialized {
                continuation.resume()
            }
        }
    }

    private func whenInitialized(_ callback: @escaping () -> Void) {
        let callback = onInitializedCallbacks.add(callback)
        if state != .initializing {
            callback()
        }
    }

    @available(iOS 13.0, *)
    override open func buildMenu(with builder: UIMenuBuilder) {
        viewModel.editingActions.buildMenu(with: builder)
        super.buildMenu(with: builder)
    }

    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.viewSizeWillChange(view.bounds.size)
    }

    override open func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        if isActive {
            viewModel.viewSizeWillChange(size)
        }
    }

    @discardableResult
    private func on(_ event: Event) -> Bool {
        assert(Thread.isMainThread, "Raising navigation events must be done from the main thread")

        if config.debugState {
            log(.debug, "-> on \(event)")
        }

        return state.transition(event)
    }

    /// Mapping between reading order hrefs and the table of contents title.
    private var tableOfContentsTitleByHref: [AnyURL: String] {
        get async { await tableOfContentsTitleByHrefTask.value }
    }

    private lazy var tableOfContentsTitleByHrefTask: Task<[AnyURL: String], Never> = Task {
        func fulfill(linkList: [Link]) -> [AnyURL: String] {
            var result = [AnyURL: String]()

            for link in linkList {
                if let title = link.title {
                    result[link.url()] = title
                }
                let subResult = fulfill(linkList: link.children)
                result.merge(subResult) { current, _ -> String in
                    current
                }
            }
            return result
        }

        guard let toc = try? await publication.tableOfContents().get() else {
            return [:]
        }

        return fulfill(linkList: toc)
    }

    /// Goes to the next or previous page in the given scroll direction.
    private func go(to direction: EPUBSpreadView.Direction, options: NavigatorGoOptions) async -> Bool {
        await go(
            to: direction,
            options: options,
            allowAdjacentPageTransaction: false
        )
    }

    private func go(
        to direction: EPUBSpreadView.Direction,
        options: NavigatorGoOptions,
        allowAdjacentPageTransaction: Bool
    ) async -> Bool {
        guard
            let paginationView = paginationView,
            (allowAdjacentPageTransaction
                ? adjacentPageTransaction != nil && isPerformingAdjacentPageNavigation
                : adjacentPageTransaction == nil),
            on(.move(direction))
        else {
            return false
        }

        if
            let spreadView = paginationView.currentView as? EPUBSpreadView,
            await spreadView.go(to: direction, options: options)
        {
            on(.moved)
            return true
        }

        let isRTL = (viewModel.readingProgression == .rtl)
        let delta = isRTL ? -1 : 1
        let moved: Bool = await {
            switch direction {
            case .left:
                let location: PageLocation = isRTL ? .start : .end
                return await paginationView.goToIndex(currentSpreadIndex - delta, location: location, options: options)
            case .right:
                let location: PageLocation = isRTL ? .end : .start
                return await paginationView.goToIndex(currentSpreadIndex + delta, location: location, options: options)
            }
        }()

        on(.moved)
        return moved
    }

    // MARK: - Pagination and spreads

    private var paginationView: PaginationView?

    private func makePaginationView(hasPositions: Bool) -> PaginationView {
        let view = PaginationView(
            frame: .zero,
            preloadPreviousPositionCount: hasPositions ? config.preloadPreviousPositionCount : 0,
            preloadNextPositionCount: hasPositions ? config.preloadNextPositionCount : 0,
            isScrollEnabled: isPaginationViewScrollingEnabled,
            layoutMode: isContinuousScrollEnabled ? .verticalContinuous : .horizontal
        )
        view.delegate = self
        view.backgroundColor = .clear
        return view
    }

    private func invalidatePaginationView() {
        guard let paginationView = paginationView else {
            return
        }

        paginationView.isScrollEnabled = isPaginationViewScrollingEnabled
        paginationView.setLayoutMode(isContinuousScrollEnabled ? .verticalContinuous : .horizontal)
        reloadSpreads()
    }

    private var spreads: [EPUBSpread] = []

    /// Index of the currently visible spread.
    private var currentSpreadIndex: Int {
        paginationView?.currentIndex ?? 0
    }

    private var needsReloadSpreadsOnActive = false

    private func reloadSpreads() {
        guard
            state != .initializing,
            isViewLoaded
        else {
            return
        }

        guard isActive else {
            // If we reload the spreads while the app is in the background, the
            // web view will reset to progression 0 instead of the current one.
            // We need to wait for the application to return to the foreground
            // to maintain the current location.
            needsReloadSpreadsOnActive = true
            return
        }

        _reloadSpreads()
    }

    private func _reloadSpreads() {
        cancelContinuousPageRemeasure()
        invalidateAdjacentPageSurfaces()
        let locator = currentLocation

        guard
            let paginationView = paginationView,
            on(.load(locator))
        else {
            return
        }

        spreads = EPUBSpread.makeSpreads(
            for: publication,
            readingOrder: readingOrder,
            readingProgression: viewModel.readingProgression,
            spread: viewModel.spreadEnabled,
            offsetFirstPage: viewModel.offsetFirstPage
        )

        let initialIndex: ReadingOrder.Index = {
            if
                let href = locator?.href,
                let index = readingOrder.firstIndexWithHREF(href),
                let foundIndex = self.spreads.firstIndexWithReadingOrderIndex(index)
            {
                return foundIndex
            } else {
                return 0
            }
        }()

        paginationView.reloadAtIndex(
            initialIndex,
            location: PageLocation(locator),
            pageCount: spreads.count,
            readingProgression: viewModel.readingProgression
        )

        on(.loaded)
    }

    private func loadedSpreadViewForHREF<T: URLConvertible>(_ href: T) -> EPUBSpreadView? {
        guard
            let loadedViews = paginationView?.loadedViews,
            let index = readingOrder.firstIndexWithHREF(href)
        else {
            return nil
        }

        return loadedViews
            .compactMap { _, view in view as? EPUBSpreadView }
            .first { $0.spread.contains(index: index) }
    }

    // MARK: - Navigator

    private var isPaginationViewScrollingEnabled: Bool {
        isUserPageTurnInteractionEnabled
            && !(config.disablePageTurnsWhileScrolling && settings.scroll && !isContinuousScrollEnabled)
    }

    /// Continuous mode is deliberately opt-in and only applies to horizontal
    /// reflowable EPUBs. Fixed-layout and vertical-writing publications retain
    /// their native horizontal presentation.
    public var isContinuousScrollEnabled: Bool {
        config.continuousScroll
            && settings.scroll
            && publication.metadata.epubLayout == .reflowable
            && !settings.verticalText
    }

    private func updatePageTurnInteraction() {
        paginationView?.isScrollEnabled = isPaginationViewScrollingEnabled
        guard let loadedViews = paginationView?.loadedViews else { return }
        for case let spreadView as EPUBSpreadView in loadedViews.values {
            spreadView.isUserPageTurnInteractionEnabled = isUserPageTurnInteractionEnabled
        }
    }

    public var presentation: VisualNavigatorPresentation {
        VisualNavigatorPresentation(
            readingProgression: settings.readingProgression,
            scroll: settings.scroll,
            axis: (settings.scroll && !settings.verticalText)
                ? .vertical
                : .horizontal
        )
    }

    private func computeCurrentLocationAndViewport() async -> (Locator?, NavigatorViewport?) {
        if case .initializing = state {
            assertionFailure("Cannot update current location when initializing the navigator")
            return (nil, nil)
        }

        // Returns any pending locator to prevent returning invalid locations
        // while loading it.
        if let pendingLocator = state.pendingLocator {
            return (pendingLocator, nil)
        }

        guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
            return (nil, nil)
        }

        if isContinuousScrollEnabled {
            let visible = paginationView?.visiblePageViews.compactMap { item -> (Int, EPUBSpreadView, CGRect)? in
                guard
                    let spreadView = item.view as? EPUBSpreadView,
                    let frame = paginationView?.pageFrame(for: item.index)
                else {
                    return nil
                }
                return (item.index, spreadView, frame)
            } ?? []

            guard
                let first = visible.first,
                let last = visible.last,
                let visibleContentRect = paginationView?.visibleContentRect
            else {
                return (nil, nil)
            }

            let firstReadingOrderIndex = first.1.spread.readingOrderIndices.lowerBound
            let lastReadingOrderIndex = last.1.spread.readingOrderIndices.upperBound
            let viewportHeight = visibleContentRect.height
            let progressionByReadingOrderIndex: (Int) -> ClosedRange<Double> = { index in
                guard let item = visible.first(where: { $0.1.spread.contains(index: index) }) else {
                    return 0 ... 0
                }

                let denominator = max(item.2.height - viewportHeight, 1)
                let lower = min(max((visibleContentRect.minY - item.2.minY) / denominator, 0), 1)
                let upper = min(max((visibleContentRect.maxY - item.2.minY) / denominator, 0), 1)
                return min(lower, upper) ... max(lower, upper)
            }

            return await EPUBViewportAndLocationCalculator.compute(
                readingOrderIndices: firstReadingOrderIndex ... lastReadingOrderIndex,
                progression: progressionByReadingOrderIndex,
                readingOrder: readingOrder,
                positionsByReadingOrder: positionsByReadingOrder,
                tableOfContentsTitleByHref: tableOfContentsTitleByHref,
                fallbackLocator: { [publication] in await publication.locate($0) }
            )
        }

        let (locator, viewport) = await EPUBViewportAndLocationCalculator.compute(
            readingOrderIndices: spreadView.spread.readingOrderIndices,
            progression: { spreadView.progression(in: $0) },
            readingOrder: readingOrder,
            positionsByReadingOrder: positionsByReadingOrder,
            tableOfContentsTitleByHref: tableOfContentsTitleByHref,
            fallbackLocator: { [publication] in await publication.locate($0) }
        )
        return (locator, viewport)
    }

    /// Deadline-bounded observation for transition reconciliation. The
    /// underlying locator calculation may consult the publication and cannot
    /// be force-cancelled safely, so the late result is deliberately dropped
    /// by the one-shot gate instead of allowing it to extend reconciliation.
    private func computeCurrentLocationAndViewport(
        deadline: UInt64
    ) async -> (Locator?, NavigatorViewport?) {
        guard deadline > DispatchTime.now().uptimeNanoseconds else {
            return (nil, nil)
        }

        let gate = PageSurfaceOneShot<(Locator?, NavigatorViewport?)>()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<(Locator?, NavigatorViewport?), Never>) in
                gate.install(continuation)
                guard !Task.isCancelled else {
                    gate.resume((nil, nil))
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self else {
                        gate.resume((nil, nil))
                        return
                    }
                    gate.resume(await self.computeCurrentLocationAndViewport())
                }

                let timeoutTask = Task { @MainActor in
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard deadline > now else {
                        gate.resume((nil, nil))
                        return
                    }
                    try? await Task.sleep(nanoseconds: deadline - now)
                    gate.resume((nil, nil))
                }
                gate.attachTimeout(timeoutTask)
            }
        }, onCancel: {
            gate.resume((nil, nil))
        })
    }

    public func firstVisibleElementLocator() async -> Locator? {
        guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
            return nil
        }
        return await spreadView.findFirstVisibleElementLocator()
    }

    // MARK: - Adjacent page surfaces

    public func prewarmAdjacentPageSurfaces(preferredDirection: NavigatorPageDirection) async {
        guard adjacentPagePrewarmToken == nil, state == .idle, adjacentPageTransaction == nil else {
            return
        }

        let prewarmToken = UUID()
        adjacentPagePrewarmToken = prewarmToken
        let prewarmEpoch = adjacentPageGeneration
        let prewarmDeadline = adjacentPageDeadline(after: 3_000_000_000)
        defer {
            if adjacentPagePrewarmToken == prewarmToken {
                adjacentPagePrewarmToken = nil
                if prewarmEpoch == adjacentPageGeneration {
                    for direction in [NavigatorPageDirection.backward, .forward]
                        where adjacentPageReadiness[direction] == .preparing
                    {
                        adjacentPageReadiness[direction] = .unknown
                    }
                }
            }
        }

        await initialized()
        guard adjacentPagePrewarmToken == prewarmToken,
              state == .idle,
              !Task.isCancelled,
              DispatchTime.now().uptimeNanoseconds < prewarmDeadline else { return }

        let preparedOrigin = (await computeCurrentLocationAndViewport(deadline: prewarmDeadline)).0
        guard adjacentPagePrewarmToken == prewarmToken,
              prewarmEpoch == adjacentPageGeneration,
              state == .idle,
              adjacentPageTransaction == nil,
              !Task.isCancelled,
              DispatchTime.now().uptimeNanoseconds < prewarmDeadline else { return }

        if let preparedOrigin {
            for direction in [NavigatorPageDirection.backward, .forward] {
                guard let surface = adjacentPageCache[direction],
                      !surface.origin.matchesAdjacentPageOrigin(preparedOrigin) else { continue }
                surface.invalidate()
                adjacentPageCache.removeValue(forKey: direction)
                adjacentPageReadiness[direction] = .unknown
            }
        }

        if let currentLocation = preparedOrigin,
           let currentView = paginationView?.currentView as? EPUBSpreadView,
           currentView.isSpreadReady,
           let image = await stableSnapshot(of: currentView, deadline: prewarmDeadline),
           adjacentPagePrewarmToken == prewarmToken,
           prewarmEpoch == adjacentPageGeneration,
           !Task.isCancelled
        {
            preparedCurrentPageSurfaceCache = NavigatorCurrentPageSurface(
                image: image,
                contentRect: pageSurfaceContentRect(in: currentView),
                identity: NavigatorPagePositionIdentity(
                    locator: currentLocation,
                    generation: prewarmEpoch
                ),
                generation: prewarmEpoch
            )
        } else {
            preparedCurrentPageSurfaceCache = nil
        }

        // Keep the cache useful across consecutive turns. This method only
        // reads already-loaded spread views or creates a detached renderer;
        // it never moves the visible navigator.
        let opposite: NavigatorPageDirection = preferredDirection == .forward ? .backward : .forward
        for direction in [preferredDirection, opposite] {
            guard adjacentPagePrewarmToken == prewarmToken,
                  prewarmEpoch == adjacentPageGeneration,
                  state == .idle,
                  adjacentPageTransaction == nil,
                  !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < prewarmDeadline else { return }
            if let surface = adjacentPageCache[direction], surface.isValid {
                adjacentPageReadiness[direction] = .ready
                continue
            }
            if adjacentPageReadiness[direction] == .unavailable {
                continue
            }
            adjacentPageReadiness[direction] = .preparing
            guard let preparedOrigin else {
                adjacentPageReadiness[direction] = .failed
                continue
            }
            let result = await buildAdjacentPageSurface(
                direction: direction,
                origin: preparedOrigin,
                generation: prewarmEpoch,
                deadline: prewarmDeadline
            )
            guard adjacentPagePrewarmToken == prewarmToken,
                  prewarmEpoch == adjacentPageGeneration,
                  state == .idle,
                  adjacentPageTransaction == nil,
                  !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < prewarmDeadline else { return }
            if let surface = result.surface {
                guard surface.generation == adjacentPageGeneration else {
                    surface.invalidate()
                    adjacentPageReadiness[direction] = .unknown
                    continue
                }
                adjacentPageCache[direction] = surface
                adjacentPageReadiness[direction] = .ready
            } else {
                adjacentPageReadiness[direction] = result.readiness
            }
        }
    }

    public func adjacentPageReadiness(direction: NavigatorPageDirection) -> NavigatorPageSurfaceReadiness {
        adjacentPageReadiness[direction] ?? .unknown
    }

    public func preparedCurrentPageSurface() -> NavigatorCurrentPageSurface? {
        guard let surface = preparedCurrentPageSurfaceCache else { return nil }
        if let currentLocation,
           !currentLocation.matchesAdjacentPageOrigin(surface.identity.locator) {
            return nil
        }
        return surface
    }

    public func preparedAdjacentPageSurface(
        direction: NavigatorPageDirection
    ) -> NavigatorPageSurface? {
        guard state == .idle,
              adjacentPageTransaction == nil,
              let surface = adjacentPageCache[direction],
              surface.isValid,
              surface.generation == adjacentPageGeneration else { return nil }
        if let currentLocation,
           !currentLocation.matchesAdjacentPageOrigin(surface.origin) {
            return nil
        }
        return surface
    }

    public func takePreparedAdjacentPage(direction: NavigatorPageDirection) -> NavigatorPageSurface? {
        // This method is intentionally O(1) during a gesture. If the
        // background warm-up did not finish, the caller must apply the light
        // edge resistance and try again after the next settled state.
        guard adjacentPageTransaction == nil, state == .idle,
              let surface = adjacentPageCache.removeValue(forKey: direction),
              surface.isValid,
              surface.generation == adjacentPageGeneration
        else {
            return nil
        }

        if let currentLocation,
           !currentLocation.matchesAdjacentPageOrigin(surface.origin) {
            surface.invalidate()
            adjacentPageReadiness[direction] = .unknown
            return nil
        }

        adjacentPageTransaction = AdjacentPageTransaction(surface: surface, phase: .prepared)
        adjacentPageReadiness[direction] = .unknown
        return surface
    }

    private struct AdjacentSurfaceBuildResult {
        let surface: NavigatorPageSurface?
        let readiness: NavigatorPageSurfaceReadiness
    }

    private struct AdjacentSurfaceTarget {
        let locator: Locator
        let leafHREF: AnyURL
        let leafIndex: Int
    }

    private func buildAdjacentPageSurface(
        direction: NavigatorPageDirection,
        origin: Locator,
        generation: Int,
        deadline: UInt64
    ) async -> AdjacentSurfaceBuildResult {
        guard state == .idle,
              adjacentPageTransaction == nil,
              DispatchTime.now().uptimeNanoseconds < deadline else {
            return .init(surface: nil, readiness: .unknown)
        }

        let token = UUID()

        guard let reflowHasPageInCurrentResource = await currentReflowPageAvailable(
            direction: direction,
            origin: origin,
            generation: generation,
            deadline: deadline
        ) else {
            // A reflow spread with no trustworthy progression must not be
            // treated as exhausted: doing so could incorrectly cross into the
            // previous/next resource while the current chapter is still
            // settling.
            return .init(surface: nil, readiness: .failed)
        }

        // First use a spread already preloaded by PaginationView when the
        // current resource is at its end. This is safe because it is off-screen
        // and has no effect on currentIndex or the visible WebView.
        if !reflowHasPageInCurrentResource,
            let targetView = loadedAdjacentSpreadView(direction: direction),
            targetView.isSpreadReady,
            let image = await stableSnapshot(of: targetView, deadline: deadline),
            let target = await targetLocator(
                for: targetView,
                direction: direction,
                generation: generation,
                deadline: deadline
            ),
            generation == adjacentPageGeneration,
            !Task.isCancelled,
            DispatchTime.now().uptimeNanoseconds < deadline
        {
            return .init(surface: NavigatorPageSurface(
                direction: direction,
                locator: target.locator,
                image: image,
                origin: origin,
                token: token,
                generation: generation,
                contentRect: pageSurfaceContentRect(in: targetView),
                leafHREF: target.leafHREF,
                leafIndex: target.leafIndex
            ), readiness: .ready)
        }

        // Reflow pagination keeps several visual pages inside one spread.
        // Build the neighboring page in a detached EPUBSpreadView instead of
        // moving the visible navigator back and forth. The same mechanism also
        // handles a preloaded-but-not-yet-loaded cross-resource spread.
        if reflowHasPageInCurrentResource,
            let currentView = paginationView?.currentView as? EPUBReflowableSpreadView,
            let renderer = await makeDetachedSpreadRenderer(
                spread: currentView.spread,
                location: .locator(origin),
                generation: generation,
                deadline: deadline
            ),
           let reflowRenderer = renderer as? EPUBReflowableSpreadView
        {
            defer {
                renderer.clear()
                renderer.superview?.removeFromSuperview()
            }
            if let image = await renderAdjacentPage(
                in: reflowRenderer,
                direction: direction,
                deadline: deadline
            ),
               let target = await targetLocator(
                   for: reflowRenderer,
                   direction: direction,
                   generation: generation,
                   deadline: deadline
               ),
               generation == adjacentPageGeneration,
               !Task.isCancelled,
               DispatchTime.now().uptimeNanoseconds < deadline
            {
                return .init(surface: NavigatorPageSurface(
                    direction: direction,
                    locator: target.locator,
                    image: image,
                    origin: origin,
                    token: token,
                    generation: generation,
                    contentRect: pageSurfaceContentRect(in: reflowRenderer),
                    leafHREF: target.leafHREF,
                    leafIndex: target.leafIndex
                ), readiness: .ready)
            }
            return .init(surface: nil, readiness: .failed)
        } else if reflowHasPageInCurrentResource {
            // The current resource still has a page in this direction. Never
            // fall through to the next chapter when its detached renderer
            // failed; that would give the gesture the wrong target identity.
            return .init(surface: nil, readiness: .failed)
        }

        guard let targetIndex = targetSpreadIndex(direction: direction),
              spreads.indices.contains(targetIndex)
        else {
            return .init(surface: nil, readiness: .unavailable)
        }

        // A missing loaded view is not a reason to touch the visible
        // navigator. Render the target spread directly in a detached view.
        if let renderer = await makeDetachedSpreadRenderer(
            spread: spreads[targetIndex],
            location: direction == .forward ? .start : .end,
            generation: generation,
            deadline: deadline
        ) {
            defer {
                renderer.clear()
                renderer.superview?.removeFromSuperview()
            }
            if let image = await stableSnapshot(of: renderer, deadline: deadline),
               let target = await targetLocator(
                   for: renderer,
                   direction: direction,
                   generation: generation,
                   deadline: deadline
               ),
               generation == adjacentPageGeneration,
               !Task.isCancelled,
               DispatchTime.now().uptimeNanoseconds < deadline
            {
                return .init(surface: NavigatorPageSurface(
                    direction: direction,
                    locator: target.locator,
                    image: image,
                    origin: origin,
                    token: token,
                    generation: generation,
                    contentRect: pageSurfaceContentRect(in: renderer),
                    leafHREF: target.leafHREF,
                    leafIndex: target.leafIndex
                ), readiness: .ready)
            }
            return .init(surface: nil, readiness: .failed)
        }

        return .init(surface: nil, readiness: .failed)
    }

    private func targetSpreadIndex(direction: NavigatorPageDirection) -> Int? {
        let index = currentSpreadIndex + (direction == .forward ? 1 : -1)
        return spreads.indices.contains(index) ? index : nil
    }

    private func loadedAdjacentSpreadView(direction: NavigatorPageDirection) -> EPUBSpreadView? {
        guard let paginationView else { return nil }
        guard let targetIndex = targetSpreadIndex(direction: direction) else { return nil }
        guard let targetView = paginationView.loadedViews[targetIndex] as? EPUBSpreadView else {
            return nil
        }
        targetView.layoutIfNeeded()
        return targetView
    }

    private func currentReflowPageAvailable(
        direction: NavigatorPageDirection,
        origin: Locator,
        generation: Int,
        deadline: UInt64
    ) async -> Bool? {
        guard !settings.scroll else { return false }
        guard let currentView = paginationView?.currentView else { return nil }
        guard let reflow = currentView as? EPUBReflowableSpreadView else { return false }

        for _ in 0..<90 {
            guard generation == adjacentPageGeneration,
                  !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < deadline else { return nil }

            if reflow.isSpreadReady {
                if let range = reflow.currentProgression {
                    switch direction {
                    case .forward:
                        return range.upperBound < 0.999
                    case .backward:
                        return range.lowerBound > 0.001
                    }
                }

                // The location calculated immediately before prewarming can
                // still be useful while the WebView's progression callback is
                // in flight. Only use it when it is an interior progression;
                // the synthetic 0...0 returned for an unknown spread must not
                // decide whether we cross a resource boundary.
                if origin.href.isEquivalentTo(reflow.spread.first.link.url()),
                   let progression = origin.locations.progression,
                   progression > 0.001,
                   progression < 0.999
                {
                    switch direction {
                    case .forward:
                        return progression < 0.999
                    case .backward:
                        return progression > 0.001
                    }
                }
            }

            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return nil }
            try? await Task.sleep(nanoseconds: min(16_000_000, deadline - now))
        }
        return nil
    }

    private func targetLocator(
        for spreadView: EPUBSpreadView,
        direction: NavigatorPageDirection,
        generation: Int,
        deadline: UInt64
    ) async -> AdjacentSurfaceTarget? {
        // FXL pages are leaf resources. The surface still represents the
        // complete spread in this phase, but its transaction identity must
        // point at the actual leaf entering from the requested side.
        if publication.metadata.layout == .fixed {
            guard generation == adjacentPageGeneration,
                  !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
            let leaf = fixedLeaf(for: spreadView.spread, direction: direction)
            let locator = Locator(
                href: leaf.link.url(),
                mediaType: leaf.link.mediaType ?? .xhtml,
                locations: .init(progression: direction == .forward ? 0 : 1)
            )
            return AdjacentSurfaceTarget(
                locator: locator,
                leafHREF: leaf.link.url(),
                leafIndex: leaf.index
            )
        }

        guard let reflow = spreadView as? EPUBReflowableSpreadView,
               let reflowProgression = await waitForPublishedProgression(
                   in: reflow,
                   generation: generation,
                   deadline: deadline
               ),
               generation == adjacentPageGeneration,
               !Task.isCancelled,
               DispatchTime.now().uptimeNanoseconds < deadline
        else { return nil }

        if let locator = await spreadView.findFirstVisibleElementLocator() {
            guard generation == adjacentPageGeneration,
                  !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
            let locator = locator.copy(locations: { $0.progression = reflowProgression })
            return makeSurfaceTarget(locator: locator, in: spreadView.spread)
        }

        let link = spreadView.spread.first.link
        let locator = Locator(
            href: link.url(),
            mediaType: link.mediaType ?? .xhtml,
            locations: .init(progression: reflowProgression)
        )
        return makeSurfaceTarget(locator: locator, in: spreadView.spread)
    }

    private func waitForPublishedProgression(
        in spreadView: EPUBReflowableSpreadView,
        generation: Int,
        deadline: UInt64
    ) async -> Double? {
        // isSpreadReady can precede the progressionChanged message by a few
        // frames on a newly detached WebView. Wait for the real value instead
        // of manufacturing 0, while making every exit cancellation- and
        // generation-safe.
        for _ in 0..<90 {
            guard generation == adjacentPageGeneration,
                  !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
            if let progression = spreadView.currentProgression {
                return progression.lowerBound
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return nil }
            try? await Task.sleep(nanoseconds: min(16_000_000, deadline - now))
        }
        return nil
    }

    private func fixedLeaf(for spread: EPUBSpread, direction: NavigatorPageDirection) -> EPUBSpreadResource {
        switch spread {
        case let .single(single):
            return single.resource
        case let .double(double):
            // `first` and `second` are in publication reading order. Moving
            // forward enters the leading leaf of the target spread; moving
            // backward enters its trailing leaf.
            return direction == .forward ? double.first : double.second
        }
    }

    private func makeSurfaceTarget(locator: Locator, in spread: EPUBSpread) -> AdjacentSurfaceTarget? {
        switch spread {
        case let .single(single):
            return AdjacentSurfaceTarget(
                locator: locator,
                leafHREF: single.resource.link.url(),
                leafIndex: single.resource.index
            )
        case let .double(double):
            if double.first.link.url().isEquivalentTo(locator.href) {
                return AdjacentSurfaceTarget(
                    locator: locator,
                    leafHREF: double.first.link.url(),
                    leafIndex: double.first.index
                )
            }
            if double.second.link.url().isEquivalentTo(locator.href) {
                return AdjacentSurfaceTarget(
                    locator: locator,
                    leafHREF: double.second.link.url(),
                    leafIndex: double.second.index
                )
            }
            // A fixed spread fallback must still identify an actual leaf.
            return AdjacentSurfaceTarget(
                locator: locator,
                leafHREF: double.first.link.url(),
                leafIndex: double.first.index
            )
        }
    }

    private func snapshot(
        of webView: WKWebView,
        deadline: UInt64
    ) async -> UIImage? {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        guard deadline > DispatchTime.now().uptimeNanoseconds else { return nil }
        webView.layoutIfNeeded()
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        // WKSnapshotConfiguration expresses snapshotWidth in points. WebKit
        // applies the screen scale when producing the UIImage; multiplying by
        // scale here would make the surface needlessly large and blurry when
        // composited by Core Animation.
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
        let gate = PageSurfaceOneShot<UIImage?>()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                gate.install(continuation)
                guard !Task.isCancelled else {
                    gate.resume(nil)
                    return
                }

                webView.takeSnapshot(with: configuration) { image, error in
                    if let error {
                        NSLog("Readium adjacent surface snapshot failed: %@", String(describing: error))
                    }
                    gate.resume(image)
                }

                let timeoutTask = Task { @MainActor in
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard deadline > now else {
                        gate.resume(nil)
                        return
                    }
                    try? await Task.sleep(nanoseconds: deadline - now)
                    gate.resume(nil)
                }
                gate.attachTimeout(timeoutTask)
            }
        }, onCancel: {
            gate.resume(nil)
        })
    }

    private func pageSurfaceContentRect(in spreadView: EPUBSpreadView) -> CGRect {
        spreadView.convert(spreadView.webView.bounds, from: spreadView.webView)
    }

    private func makeDetachedSpreadRenderer(
        spread: EPUBSpread,
        location: PageLocation,
        generation: Int,
        deadline: UInt64
    ) async -> EPUBSpreadView? {
        guard generation == adjacentPageGeneration,
              !Task.isCancelled,
              DispatchTime.now().uptimeNanoseconds < deadline,
              let paginationView,
              paginationView.bounds.width > 0,
              paginationView.bounds.height > 0 else { return nil }

        paginationView.layoutIfNeeded()
        let viewportSize = paginationView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }

        let host = UIView(frame: CGRect(x: -20000, y: -20000, width: viewportSize.width, height: viewportSize.height))
        host.isUserInteractionEnabled = false
        host.backgroundColor = .clear
        view.addSubview(host)

        let renderer = makeSpreadView(for: spread, receivesNavigatorEvents: false)
        if let currentView = paginationView.currentView as? EPUBSpreadView {
            renderer.surfaceContentInset = spreadViewContentInset(currentView)
        }
        renderer.frame = host.bounds
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(renderer)
        renderer.layoutIfNeeded()

        guard generation == adjacentPageGeneration,
              viewportSizeApproximatelyMatches(paginationView.bounds.size, viewportSize),
              await waitForSpreadLoaded(renderer, deadline: deadline) else {
            renderer.clear()
            renderer.removeFromSuperview()
            host.removeFromSuperview()
            return nil
        }
        guard generation == adjacentPageGeneration,
              viewportSizeApproximatelyMatches(paginationView.bounds.size, viewportSize),
              !Task.isCancelled,
              DispatchTime.now().uptimeNanoseconds < deadline else {
            renderer.clear()
            renderer.removeFromSuperview()
            host.removeFromSuperview()
            return nil
        }
        await renderer.go(to: location, animated: false)
        guard !Task.isCancelled,
              generation == adjacentPageGeneration,
              DispatchTime.now().uptimeNanoseconds < deadline else {
            renderer.clear()
            renderer.removeFromSuperview()
            host.removeFromSuperview()
            return nil
        }
        host.accessibilityElementsHidden = true
        return renderer
    }

    private func viewportSizeApproximatelyMatches(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 0.5 && abs(lhs.height - rhs.height) <= 0.5
    }

    private func waitForSpreadLoaded(_ spreadView: EPUBSpreadView, deadline: UInt64) async -> Bool {
        // Do not await EPUBSpreadView.spreadLoaded() here: it is backed by a
        // continuation and cannot be safely cancelled while a detached WebKit
        // process is being torn down. Polling gives both cancellation and a
        // bounded cleanup path.
        for _ in 0..<120 {
            if spreadView.isSpreadReady { return true }
            guard !Task.isCancelled else { return false }
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return false }
            try? await Task.sleep(nanoseconds: min(16_000_000, deadline - now))
        }
        return false
    }

    private func stableSnapshot(of spreadView: EPUBSpreadView, deadline: UInt64) async -> UIImage? {
        guard spreadView.isSpreadReady,
              deadline > DispatchTime.now().uptimeNanoseconds,
              await waitForStablePaint(of: spreadView, deadline: deadline),
              await waitForPageBoundary(of: spreadView, deadline: deadline),
              !Task.isCancelled
        else { return nil }
        return await snapshot(of: spreadView.webView, deadline: deadline)
    }

    /// How far off a page boundary a position may be and still be snapshotted,
    /// as a fraction of one page.
    private var pageBoundaryAlignmentTolerance: Double { 0.02 }

    /// Waits until the horizontal pagination is resting on a page boundary.
    ///
    /// Two painted frames are not enough. The web view is a multi-column
    /// document, so a scroll offset that is not a whole number of viewports
    /// captures the tail of one page and the head of the next.
    ///
    /// The page script already re-snaps on any body resize — its ResizeObserver
    /// calls `snapCurrentPosition` — so a reflow does not leave the position
    /// permanently wrong. The failure is one of timing: the snap lands in a
    /// `requestAnimationFrame` that can easily run after these two frames, and
    /// the snapshot then captures the pre-snap position. Waiting for the
    /// position itself, rather than for a frame count, is what closes that
    /// window; no corrective navigation is needed.
    ///
    /// Returning false fails the snapshot, which is deliberate: a half page must
    /// never become a page surface. The caller retries on its next prewarm.
    private func waitForPageBoundary(of spreadView: EPUBSpreadView, deadline: UInt64) async -> Bool {
        guard spreadView.requiresPageBoundaryAlignment else { return true }

        for _ in 0..<30 {
            if let residual = spreadView.pageBoundaryResidual,
               residual <= pageBoundaryAlignmentTolerance {
                return true
            }
            guard !Task.isCancelled else { return false }
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return false }
            try? await Task.sleep(nanoseconds: min(16_000_000, deadline - now))
        }
        return false
    }

    private func waitForStablePaint(of spreadView: EPUBSpreadView, deadline: UInt64) async -> Bool {
        guard spreadView.isSpreadReady else { return false }
        guard deadline > DispatchTime.now().uptimeNanoseconds else { return false }
        let barrier = TwoFramePaintBarrier()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                barrier.start(continuation, deadline: deadline)
            }
        }, onCancel: {
            Task { @MainActor in
                barrier.cancel()
            }
        })
    }

    private func renderAdjacentPage(
        in renderer: EPUBReflowableSpreadView,
        direction: NavigatorPageDirection,
        deadline: UInt64
    ) async -> UIImage? {
        guard deadline > DispatchTime.now().uptimeNanoseconds else { return nil }
        let visualDirection: EPUBSpreadView.Direction = direction == .forward
            ? (viewModel.readingProgression == .rtl ? .left : .right)
            : (viewModel.readingProgression == .rtl ? .right : .left)
        let previousProgression = renderer.currentProgression
        guard await renderer.go(to: visualDirection, options: .none) else {
            return nil
        }
        // The renderer must publish a new progression after the detached go.
        // Merely waiting a fixed duration would allow a delayed callback to
        // leave the surface identified by the origin page.
        guard await waitForReflowProgressionChange(
            renderer,
            from: previousProgression,
            deadline: deadline
        ) else {
            return nil
        }
        return await stableSnapshot(of: renderer, deadline: deadline)
    }

    private func waitForReflowProgressionChange(
        _ renderer: EPUBReflowableSpreadView,
        from previous: ClosedRange<Double>?,
        deadline: UInt64
    ) async -> Bool {
        for _ in 0..<90 {
            if let progression = renderer.currentProgression,
               progression != previous
            {
                return true
            }
            guard !Task.isCancelled else { return false }
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return false }
            try? await Task.sleep(nanoseconds: min(16_000_000, deadline - now))
        }
        return false
    }

    public func invalidateAdjacentPageSurfaces() {
        if adjacentPageTransaction?.phase == .committing {
            // External navigation requests takeover, but the live mutation
            // still owns the navigator until its goToIndex call returns.
            // This preserves the jump/jumped pair and prevents a second
            // mutation from racing the first one.
            adjacentPageTransaction?.externalNavigationRequested = true
            adjacentPageTransaction?.cancelRequested = true
            adjacentPageGeneration &+= 1
            for surface in adjacentPageCache.values {
                surface.invalidate()
            }
            adjacentPageCache.removeAll()
            preparedCurrentPageSurfaceCache = nil
            adjacentPageReadiness = [.backward: .unknown, .forward: .unknown]
            return
        }

        adjacentPageGeneration &+= 1
        adjacentPageTransaction?.surface.invalidate()
        adjacentPageTransaction = nil
        for surface in adjacentPageCache.values {
            surface.invalidate()
        }
        adjacentPageCache.removeAll()
        preparedCurrentPageSurfaceCache = nil
        adjacentPageReadiness = [.backward: .unknown, .forward: .unknown]
    }

    @discardableResult
    public func commitAdjacentPageResult(_ surface: NavigatorPageSurface) async -> NavigatorPageCommitResult {
        guard var transaction = adjacentPageTransaction,
              transaction.phase == .prepared,
              transaction.surface === surface,
              surface.isValid,
              surface.generation == adjacentPageGeneration
        else {
            return .indeterminate
        }

        let activeSurface = transaction.surface
        let transactionDeadline = adjacentPageDeadline(after: 2_000_000_000)
        transaction.phase = .committing
        adjacentPageTransaction = transaction
        defer {
            finishAdjacentPageCommit(surface: activeSurface)
        }

        let (location, _) = await computeCurrentLocationAndViewport(deadline: transactionDeadline)
        guard DispatchTime.now().uptimeNanoseconds < transactionDeadline else {
            return .indeterminate
        }
        guard ownsAdjacentPageTransaction(surface), !isExternalNavigationRequested else {
            return .indeterminate
        }
        guard let location, location.matchesAdjacentPageOrigin(activeSurface.origin) else {
            return .indeterminate
        }
        guard !isCancelRequested, !Task.isCancelled else { return .restored }

        suppressLocationNotifications = true
        isPerformingAdjacentPageNavigation = true
        let visualDirection: EPUBSpreadView.Direction = {
            switch (activeSurface.direction, viewModel.readingProgression) {
            case (.forward, .ltr), (.backward, .rtl):
                return .right
            case (.forward, .rtl), (.backward, .ltr):
                return .left
            }
        }()
        let moved = await go(
            to: visualDirection,
            options: .none,
            allowAdjacentPageTransaction: true
        )

        guard ownsAdjacentPageTransaction(surface), !isExternalNavigationRequested else {
            return await reconcileAdjacentPageOutcome(activeSurface, deadline: transactionDeadline)
        }

        if isCancelRequested || Task.isCancelled {
            return await restoreAdjacentPageOrigin(
                activeSurface,
                deadline: adjacentPageDeadline(after: 1_200_000_000)
            )
        }

        if !moved {
            let outcome = await resolveAdjacentPageLocation(
                activeSurface,
                deadline: adjacentPageDeadline(after: 600_000_000)
            )
            guard outcome == .indeterminate else { return outcome }
            return await restoreAdjacentPageOrigin(
                activeSurface,
                deadline: adjacentPageDeadline(after: 1_200_000_000)
            )
        }

        guard await waitForSettledTarget(activeSurface, deadline: transactionDeadline) else {
            if isCancelRequested || Task.isCancelled {
                return await restoreAdjacentPageOrigin(
                    activeSurface,
                    deadline: adjacentPageDeadline(after: 1_200_000_000)
                )
            }
            return await resolveAdjacentPageLocation(
                activeSurface,
                deadline: adjacentPageDeadline(after: 600_000_000)
            )
        }
        guard ownsAdjacentPageTransaction(surface), !isExternalNavigationRequested else {
            return await resolveAdjacentPageLocation(
                activeSurface,
                deadline: adjacentPageDeadline(after: 600_000_000)
            )
        }

        // Every cached neighbor was rendered for the old origin. Once the
        // target becomes current, retaining any of them would allow a later
        // gesture to animate to a stale locator/snapshot.
        for cachedSurface in adjacentPageCache.values {
            cachedSurface.invalidate()
        }
        adjacentPageCache.removeAll()
        preparedCurrentPageSurfaceCache = nil
        updateCurrentLocation()
        return .committed
    }

    /// Reconciles a commit whose transaction ended without proving whether
    /// the target or origin won. This method never navigates: it only observes
    /// the real locator and waits for a stable visible paint before reporting
    /// a terminal outcome.
    public func reconcileAdjacentPageResult(
        _ surface: NavigatorPageSurface,
        deadline: UInt64
    ) async -> NavigatorPageCommitResult {
        for _ in 0..<60 {
            guard !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < deadline else { return .indeterminate }
            if let current = (await computeCurrentLocationAndViewport(deadline: deadline)).0 {
                if targetLocationMatches(current, surface),
                   await waitForStableVisibleAdjacentPage(deadline: deadline) {
                    return .committed
                }
                if current.matchesAdjacentPageOrigin(surface.origin),
                   await waitForStableVisibleAdjacentPage(deadline: deadline) {
                    return .restored
                }
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return .indeterminate }
            try? await Task.sleep(nanoseconds: min(16_000_000, deadline - now))
        }
        return .indeterminate
    }

    private func waitForStableVisibleAdjacentPage(deadline: UInt64) async -> Bool {
        guard let spread = paginationView?.currentView as? EPUBSpreadView,
              spread.isSpreadReady,
              await waitForStablePaint(of: spread, deadline: deadline),
              await snapshot(of: spread.webView, deadline: deadline) != nil
        else { return false }
        return true
    }

    private func ownsAdjacentPageTransaction(_ surface: NavigatorPageSurface) -> Bool {
        adjacentPageTransaction?.phase == .committing
            && adjacentPageTransaction?.surface === surface
    }

    private var isCancelRequested: Bool {
        adjacentPageTransaction?.cancelRequested == true
    }

    private var isExternalNavigationRequested: Bool {
        adjacentPageTransaction?.externalNavigationRequested == true
    }

    private func finishAdjacentPageCommit(surface: NavigatorPageSurface) {
        guard let transaction = adjacentPageTransaction,
              transaction.surface === surface else { return }
        let shouldRefreshLocation = !transaction.externalNavigationRequested

        // Roll the cache forward instead of emptying it.
        //
        // A surface binds its direction, origin and generation at construction
        // and is immutable, so none of these can be reused as-is — but the
        // pixels are only an image of a page, and the pages that survive a turn
        // are exactly the two already in hand: the one just turned to, and the
        // one just left. Promoting them means the next prewarm renders only the
        // one genuinely new page rather than all three.
        //
        // This is fail-safe. A promoted surface is only accepted if the
        // navigator's settled location still matches its locator, so a mismatch
        // simply falls back to a full prewarm — the behaviour without this.
        let committed = surface
        let departed = preparedCurrentPageSurfaceCache

        surface.invalidate()
        adjacentPageTransaction = nil
        for cached in adjacentPageCache.values {
            cached.invalidate()
        }
        adjacentPageCache.removeAll()
        preparedCurrentPageSurfaceCache = nil

        adjacentPageGeneration &+= 1
        let generation = adjacentPageGeneration

        preparedCurrentPageSurfaceCache = NavigatorCurrentPageSurface(
            image: committed.image,
            contentRect: committed.geometry.contentRect,
            identity: NavigatorPagePositionIdentity(
                locator: committed.locator,
                generation: generation
            ),
            generation: generation
        )

        // The page we left is now the neighbour on the side we turned away
        // from. The leaf fields are not carried across: the current-page
        // surface does not record them, and they only matter for fixed-layout
        // spreads, which do not take this path.
        let departedDirection: NavigatorPageDirection =
            committed.direction == .forward ? .backward : .forward
        if let departed {
            adjacentPageCache[departedDirection] = NavigatorPageSurface(
                direction: departedDirection,
                locator: departed.identity.locator,
                image: departed.image,
                origin: committed.locator,
                token: UUID(),
                generation: generation,
                contentRect: departed.geometry.contentRect
            )
            adjacentPageReadiness[departedDirection] = .ready
            adjacentPageReadiness[departedDirection == .forward ? .backward : .forward] = .unknown
        } else {
            adjacentPageReadiness = [.backward: .unknown, .forward: .unknown]
        }

        isPerformingAdjacentPageNavigation = false
        suppressLocationNotifications = false
        if shouldRefreshLocation {
            updateCurrentLocation()
        }
    }

    private func restoreAdjacentPageOrigin(
        _ surface: NavigatorPageSurface,
        deadline: UInt64
    ) async -> NavigatorPageCommitResult {
        // Keep rollback on the navigator's actor even when the gesture task
        // itself was cancelled; the mutation must finish before takeover.
        let restoration: Task<NavigatorPageCommitResult, Never> = Task { @MainActor [weak self] in
            guard let self else { return .indeterminate }
            return await self.performAdjacentPageOriginRestore(surface, deadline: deadline)
        }
        return await restoration.value
    }

    private func performAdjacentPageOriginRestore(
        _ surface: NavigatorPageSurface,
        deadline: UInt64
    ) async -> NavigatorPageCommitResult {
        // Retry the compensating navigation once. Each attempt is bounded by
        // waitForSettledOrigin; after every failed attempt, reconcile the
        // actual locator before deciding whether another go is safe.
        for _ in 0..<2 {
            if !isExternalNavigationRequested,
               ownsAdjacentPageTransaction(surface)
            {
                let moved = await go(
                    to: surface.origin,
                    options: .none,
                    allowAdjacentPageTransaction: true
                )
                if moved,
                   ownsAdjacentPageTransaction(surface),
                   !isExternalNavigationRequested,
                   await waitForSettledOrigin(surface, deadline: deadline)
                {
                    return .restored
                }
            }

            let outcome = await reconcileAdjacentPageOutcome(surface, deadline: deadline)
            switch outcome {
            case .committed, .restored:
                return outcome
            case .indeterminate:
                continue
            }
        }

        return await reconcileAdjacentPageOutcome(surface, deadline: deadline)
    }

    /// Reads the post-failure navigator state without navigating. This is the
    /// final guard against reporting a failed commit when the target actually
    /// won, or asking an upper layer to tear down a transition whose location
    /// is not known yet.
    private func reconcileAdjacentPageOutcome(
        _ surface: NavigatorPageSurface,
        deadline: UInt64
    ) async -> NavigatorPageCommitResult {
        guard let current = (await computeCurrentLocationAndViewport(deadline: deadline)).0 else {
            return .indeterminate
        }
        if targetLocationMatches(current, surface) {
            return .committed
        }
        if current.matchesAdjacentPageOrigin(surface.origin) {
            return .restored
        }
        return .indeterminate
    }

    /// Resolves the actual navigator position without mutating it. A slow
    /// stable paint must never be interpreted as permission to navigate back.
    private func resolveAdjacentPageLocation(
        _ surface: NavigatorPageSurface,
        deadline: UInt64
    ) async -> NavigatorPageCommitResult {
        let outcome = await reconcileAdjacentPageOutcome(surface, deadline: deadline)
        guard outcome != .indeterminate,
              await waitForStableVisibleAdjacentPage(deadline: deadline) else {
            return .indeterminate
        }
        let confirmedOutcome = await reconcileAdjacentPageOutcome(surface, deadline: deadline)
        return confirmedOutcome == outcome ? outcome : .indeterminate
    }

    private func adjacentPageDeadline(after duration: UInt64) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &+ duration
    }

    private func waitForSettledOrigin(
        _ surface: NavigatorPageSurface,
        deadline: UInt64
    ) async -> Bool {
        for _ in 0..<60 {
            guard DispatchTime.now().uptimeNanoseconds < deadline,
                  ownsAdjacentPageTransaction(surface),
                  !isExternalNavigationRequested
            else { return false }

            if let current = (await computeCurrentLocationAndViewport(deadline: deadline)).0,
               ownsAdjacentPageTransaction(surface),
               current.matchesAdjacentPageOrigin(surface.origin),
               let spread = paginationView?.currentView as? EPUBSpreadView,
               spread.isSpreadReady
            {
                guard await waitForStablePaint(of: spread, deadline: deadline),
                      ownsAdjacentPageTransaction(surface),
                      !isExternalNavigationRequested
                else { return false }
                guard await snapshot(of: spread.webView, deadline: deadline) != nil,
                      ownsAdjacentPageTransaction(surface),
                      !isExternalNavigationRequested
                else { return false }
                return true
            }

            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        return false
    }

    private func isActiveAdjacentSurface(_ surface: NavigatorPageSurface) -> Bool {
        guard let activeSurface = adjacentPageTransaction?.surface else { return false }
        return activeSurface === surface
            && activeSurface.isValid
            && activeSurface.generation == adjacentPageGeneration
    }

    private func waitForSettledTarget(
        _ surface: NavigatorPageSurface,
        deadline: UInt64
    ) async -> Bool {
        let target = surface.locator
        for _ in 0..<60 {
            guard DispatchTime.now().uptimeNanoseconds < deadline,
                  isActiveAdjacentSurface(surface),
                  !isCancelRequested,
                  !isExternalNavigationRequested
            else { return false }
            if let current = (await computeCurrentLocationAndViewport(deadline: deadline)).0,
               isActiveAdjacentSurface(surface),
               targetLocationMatches(current, surface),
               let spread = paginationView?.currentView as? EPUBSpreadView,
               spread.isSpreadReady
            {
                // Keep the immutable surface in place through two complete
                // run-loop turns. This prevents WebKit's first post-navigation
                // paint from flashing through the transition layer.
                guard await waitForStablePaint(of: spread, deadline: deadline), isActiveAdjacentSurface(surface) else {
                    return false
                }
                guard await snapshot(of: spread.webView, deadline: deadline) != nil, isActiveAdjacentSurface(surface) else {
                    return false
                }
                return true
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        return false
    }

    private func targetLocationMatches(_ current: Locator, _ surface: NavigatorPageSurface) -> Bool {
        let target = surface.locator
        if publication.metadata.layout == .fixed {
            // A fixed spread can expose either leaf as its current locator,
            // even though the transaction has a directional leaf identity.
            // Verify that the committed spread contains that exact leaf; a
            // matching href alone is not sufficient to prove the spread has
            // settled (and would be wrong for a double-page spread).
            guard let leafIndex = surface.leafIndex,
                  let spread = paginationView?.currentView as? EPUBSpreadView,
                  spread.spread.contains(index: leafIndex)
            else { return false }
            return true
        }
        guard current.href.isEquivalentTo(target.href) else { return false }
        guard let expected = target.locations.progression,
              let actual = current.locations.progression
        else { return false }
        let delta = abs(expected - actual)
#if DEBUG
        if delta >= adjacentPageProgressionTolerance {
            print(
                "Adjacent page mismatch expected=\(expected) actual=\(actual) "
                    + "delta=\(delta) href=\(target.href) generation=\(surface.generation)"
            )
        }
#endif
        return delta < adjacentPageProgressionTolerance
    }

    public func cancelAdjacentPage(_ surface: NavigatorPageSurface) {
        guard let transaction = adjacentPageTransaction,
              transaction.surface === surface else {
            return
        }
        if transaction.phase == .committing {
            // Commit owns the origin once navigation has begun. Let it
            // observe the cancellation and perform the bounded rollback.
            adjacentPageTransaction?.cancelRequested = true
            return
        }
        let direction = transaction.surface.direction
        surface.invalidate()
        adjacentPageTransaction = nil
        adjacentPageReadiness[direction] = .unknown
    }

    /// Last current location notified to the delegate.
    /// Used to avoid sending twice the same location.
    private var notifiedCurrentLocation: Locator?

    private lazy var updateCurrentLocation = execute(
        // If we're not in an `idle` state, we postpone the notification.
        when: { [weak self] in self?.state == .idle },
        pollingInterval: 0.1
    ) { [weak self] in
        guard let self = self else {
            return
        }

        (currentLocation, viewport) = await computeCurrentLocationAndViewport()

        if
            !suppressLocationNotifications,
            let delegate = delegate,
            let location = currentLocation,
            location != notifiedCurrentLocation
        {
            notifiedCurrentLocation = location
            delegate.navigator(self, locationDidChange: location)
        }
    }

    private func waitForAdjacentPageTransactionToSettle() async -> Bool {
        for _ in 0..<180 {
            if adjacentPageTransaction == nil {
                return true
            }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        return adjacentPageTransaction == nil
    }

    public func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool {
        guard await waitForAdjacentPageTransactionToSettle() else { return false }
        return await go(
            to: locator,
            options: options,
            allowAdjacentPageTransaction: false
        )
    }

    private func go(
        to locator: Locator,
        options: NavigatorGoOptions,
        allowAdjacentPageTransaction: Bool
    ) async -> Bool {
        let owningSurface = allowAdjacentPageTransaction
            ? adjacentPageTransaction?.surface
            : nil
        if allowAdjacentPageTransaction {
            guard owningSurface != nil, isPerformingAdjacentPageNavigation else { return false }
        } else {
            guard adjacentPageTransaction == nil else { return false }
            invalidateAdjacentPageSurfaces()
        }
        let locator = publication.normalizeLocator(locator)

        guard
            let paginationView = paginationView,
            let index = readingOrder.firstIndexWithHREF(locator.href),
            let spreadIndex = spreads.firstIndexWithReadingOrderIndex(index),
            on(.jump(locator))
        else {
            return false
        }

        let success = await paginationView.goToIndex(spreadIndex, location: .locator(locator), options: options)
        if let owningSurface, !ownsAdjacentPageTransaction(owningSurface) {
            return false
        }
        on(.jumped)
        if success, !suppressLocationNotifications {
            delegate?.navigator(self, didJumpTo: locator)
        }
        return success
    }

    public func go(to link: Link, options: NavigatorGoOptions) async -> Bool {
        guard let locator = await publication.locate(link) else {
            return false
        }
        return await go(to: locator, options: options)
    }

    @discardableResult
    public func goForward(options: NavigatorGoOptions) async -> Bool {
        guard await waitForAdjacentPageTransactionToSettle(), adjacentPageTransaction == nil else { return false }
        invalidateAdjacentPageSurfaces()
        let direction: EPUBSpreadView.Direction = {
            switch viewModel.readingProgression {
            case .ltr:
                return .right
            case .rtl:
                return .left
            }
        }()
        return await go(to: direction, options: options)
    }

    @discardableResult
    public func goBackward(options: NavigatorGoOptions) async -> Bool {
        guard await waitForAdjacentPageTransactionToSettle(), adjacentPageTransaction == nil else { return false }
        invalidateAdjacentPageSurfaces()
        let direction: EPUBSpreadView.Direction = {
            switch viewModel.readingProgression {
            case .ltr:
                return .left
            case .rtl:
                return .right
            }
        }()
        return await go(to: direction, options: options)
    }

    // MARK: - SelectableNavigator

    public var currentSelection: Selection? {
        viewModel.editingActions.selection
    }

    public func clearSelection() {
        guard let paginationView = paginationView else {
            return
        }

        for (_, pageView) in paginationView.loadedViews {
            (pageView as? EPUBSpreadView)?.webView.clearSelection()
        }
    }

    // MARK: - DecorableNavigator

    private var decorations: [DecorationGroup: [DiffableDecoration]] = [:]

    /// Decoration group callbacks, indexed by the group name.
    private var decorationCallbacks: [DecorationGroup: [DecorableNavigator.OnActivatedCallback]] = [:]

    /// Pending decoration tasks, indexed by group name. Stored to allow
    /// cancellation when a new `apply(decorations:in:)` call supersedes a
    /// previous one.
    private var decorationTasks: [DecorationGroup: Task<Void, Never>] = [:]

    public func supports(decorationStyle style: Decoration.Style.Id) -> Bool {
        config.decorationTemplates.keys.contains(style)
    }

    public func apply(decorations: [Decoration], in group: DecorationGroup) {
        decorationTasks[group]?.cancel()
        var task: Task<Void, Never>?
        task = Task { [weak self] in
            defer {
                if let self, self.decorationTasks[group] == task {
                    self.decorationTasks[group] = nil
                }
            }
            guard let self else { return }
            await self.initialized()

            guard
                !Task.isCancelled,
                let paginationView = self.paginationView
            else {
                return
            }

            await withTaskGroup(of: Void.self) { tasks in
                guard !Task.isCancelled else { return }

                let source = self.decorations[group] ?? []
                let target = decorations.map {
                    var d = $0
                    d.locator = self.publication.normalizeLocator(d.locator)
                    return DiffableDecoration(decoration: d)
                }
                self.decorations[group] = target

                if decorations.isEmpty {
                    for (_, pageView) in paginationView.loadedViews {
                        tasks.addTask {
                            guard !Task.isCancelled else { return }
                            await (pageView as? EPUBSpreadView)?.evaluateScript(
                                // The updates command are using `requestAnimationFrame()`, so we need it for
                                // `clear()` as well otherwise we might recreate a highlight after it has been
                                // cleared.
                                "requestAnimationFrame(function () { readium.getDecorations('\(group)').clear(); });"
                            )
                        }
                    }
                } else {
                    for (href, changes) in target.changesByHREF(from: source) {
                        guard let script = changes.javascript(forGroup: group, styles: self.config.decorationTemplates) else {
                            continue
                        }
                        tasks.addTask { @MainActor [weak self] in
                            guard
                                !Task.isCancelled,
                                let spreadView = self?.loadedSpreadViewForHREF(href),
                                spreadView.isSpreadLoaded
                            else {
                                return
                            }
                            await spreadView.evaluateScript(script, inHREF: href)
                        }
                    }
                }
            }
        }
        decorationTasks[group] = task
    }

    public func observeDecorationInteractions(inGroup group: DecorationGroup, onActivated: @escaping OnActivatedCallback) {
        var callbacks = decorationCallbacks[group] ?? []
        callbacks.append(onActivated)
        decorationCallbacks[group] = callbacks

        Task {
            await initialized()

            guard let paginationView = paginationView else {
                return
            }

            await withTaskGroup(of: Void.self) { tasks in
                for (_, view) in paginationView.loadedViews {
                    tasks.addTask {
                        await (view as? EPUBSpreadView)?.evaluateScript("readium.getDecorations('\(group)').setActivable();")
                    }
                }
            }
        }
    }

    // MARK: - Configurable

    public var settings: EPUBSettings {
        viewModel.settings
    }

    public func submitPreferences(_ preferences: EPUBPreferences) {
        invalidateAdjacentPageSurfaces()
        viewModel.submitPreferences(preferences)
        applySettings()

        delegate?.navigator(self, presentationDidChange: presentation)
    }

    /// Re-applies the content insets supplied by `navigatorContentInset(_:)`.
    ///
    /// Call this when the host's geometry changed but the navigator's own
    /// bounds did not, for example when a reserved chrome area above or below
    /// the navigator was resized. Unlike `submitPreferences(_:)` it neither
    /// rebuilds the settings nor discards the prepared page surfaces.
    public func refreshContentInsets() {
        guard let paginationView = paginationView else {
            return
        }

        for pageView in paginationView.loadedViews.values {
            (pageView as? EPUBSpreadView)?.refreshContentInset()
        }
    }

    public func editor(of preferences: EPUBPreferences) -> EPUBPreferencesEditor {
        viewModel.editor(of: preferences)
    }

    /// Applies user settings that require native configuration instead of
    /// CSS properties.
    private func applySettings() {
        guard isViewLoaded else {
            return
        }

        view.backgroundColor = settings.effectiveBackgroundColor.uiColor
        updatePageTurnInteraction()
    }

    // MARK: - EPUB-specific extensions

    /// Evaluates the given JavaScript on the currently visible HTML resource.
    @discardableResult
    public func evaluateJavaScript(_ script: String) async -> Result<Any, Error> {
        guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
            return .failure(EPUBError.spreadNotLoaded)
        }
        return await spreadView.evaluateScript(script)
    }

    // MARK: - UIAccessibilityAction

    override open func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard !super.accessibilityScroll(direction) else {
            return true
        }

        let options = NavigatorGoOptions(animated: false)

        Task {
            switch direction {
            case .right:
                await goLeft(options: options)
            case .left:
                await goRight(options: options)
            case .next, .down:
                await goForward(options: options)
            case .previous, .up:
                await goBackward(options: options)
            @unknown default:
                break
            }
        }
        return true
    }
}

private extension Locator {
    /// WebKit can report tiny floating-point progression drift after restoring
    /// the same reflowable page. Keep the tolerance well below a real page
    /// step; `position` is resource-level and can be shared by many pages.
    func matchesAdjacentPageOrigin(_ other: Locator) -> Bool {
        guard href == other.href else { return false }
        if let progression = locations.progression,
           let otherProgression = other.locations.progression {
            return abs(progression - otherProgression) <= 0.0001
        }
        if !locations.fragments.isEmpty || !other.locations.fragments.isEmpty {
            return locations.fragments == other.locations.fragments
        }
        if let position = locations.position, let otherPosition = other.locations.position {
            return position == otherPosition
        }
        return self == other
    }
}

extension EPUBNavigatorViewController: EPUBNavigatorViewModelDelegate {
    func epubNavigatorViewModelInvalidatePaginationView(_ viewModel: EPUBNavigatorViewModel) {
        invalidatePaginationView()
    }

    func epubNavigatorViewModel(_ viewModel: EPUBNavigatorViewModel, runScript script: String, in scope: EPUBScriptScope) {
        Task {
            await initialized()

            guard let paginationView = paginationView else {
                return
            }

            switch scope {
            case .currentResource:
                await (paginationView.currentView as? EPUBSpreadView)?.evaluateScript(script)

            case .loadedResources:
                await withTaskGroup(of: Void.self) { tasks in
                    for (_, view) in paginationView.loadedViews {
                        tasks.addTask {
                            await (view as? EPUBSpreadView)?.evaluateScript(script)
                        }
                    }
                }

            case let .resource(href):
                for (_, view) in paginationView.loadedViews {
                    guard
                        let view = view as? EPUBSpreadView,
                        let index = readingOrder.firstIndexWithHREF(href),
                        view.spread.contains(index: index)
                    else {
                        continue
                    }
                    await view.evaluateScript(script, inHREF: href)
                    return
                }
            }
        }
    }

    func epubNavigatorViewModel(
        _ viewModel: EPUBNavigatorViewModel,
        didFailToLoadResourceAt href: RelativeURL,
        withError error: ReadError
    ) {
        DispatchQueue.main.async {
            self.delegate?.navigator(self, didFailToLoadResourceAt: href, withError: error)
        }
    }
}

extension EPUBNavigatorViewController: EPUBSpreadViewDelegate {
    func spreadViewContentInset(_ spreadView: EPUBSpreadView) -> UIEdgeInsets {
        if let inset = delegate?.navigatorContentInset(self) {
            return inset
        }

        // We use the window's safeAreaInsets instead of the view's because we
        // only want to take into account the device notch and status bar, not
        // the application's bars.
        var insets = view.window?.safeAreaInsets ?? .zero

        switch publication.metadata.epubLayout {
        case .fixed:
            // With iPadOS and macOS, we aim to display content edge-to-edge
            // since there are no physical notches or Dynamic Island like on the
            // iPhone.
            if UIDevice.current.userInterfaceIdiom != .phone {
                insets = .zero
            }

        case .reflowable:
            let configInset = config.contentInset(for: view.traitCollection.verticalSizeClass)
            insets.top = max(insets.top, configInset.top)
            insets.bottom = max(insets.bottom, configInset.bottom)
        }

        return insets
    }

    func spreadViewDidLoad(_ spreadView: EPUBSpreadView) async {
        let templates = config.decorationTemplates.reduce(into: [String: JSONValue]()) { styles, item in
            styles[item.key.rawValue] = .object(item.value.jsonObject)
        }

        guard let stylesJSON = try? templates.jsonString() else {
            log(.error, "Can't serialize decoration styles to JSON")
            return
        }
        var script = "readium.registerDecorationTemplates(\(stylesJSON.replacingOccurrences(of: "\\n", with: " ")));\n"

        script += decorationCallbacks
            .compactMap { group, callbacks in
                guard !callbacks.isEmpty else {
                    return nil
                }
                return "readium.getDecorations('\(group)').setActivable();"
            }
            .joined(separator: "\n")

        let links = spreadView.spread.readingOrderIndices
            .compactMap { readingOrder.getOrNil($0) }

        for link in links {
            let href = link.url()
            for (group, decorations) in decorations {
                let decorations = decorations
                    .filter { $0.decoration.locator.href.isEquivalentTo(href) }
                    .map { DecorationChange.add($0.decoration) }

                guard let decorationsScript = decorations.javascript(forGroup: group, styles: config.decorationTemplates) else {
                    continue
                }
                script += decorationsScript
            }
        }

        await spreadView.evaluateScript("(function() {\n\(script)\n})();")
    }

    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: PointerEvent) {
        Task {
            var event = event
            event.location = view.convert(event.location, from: spreadView)
            if let targetElement = event.targetElement {
                event.targetElement?.frame = view.convert(targetElement.frame, from: spreadView)
            }
            _ = await inputObservers.didReceive(event)
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didReceive event: KeyEvent) {
        Task {
            _ = await inputObservers.didReceive(event)
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didTapOnExternalURL url: URL) {
        guard state == .idle else { return }

        delegate?.navigator(self, presentExternalURL: url)
    }

    func spreadView(_ spreadView: EPUBSpreadView, didTapOnInternalLink href: String, clickEvent: ClickEvent?) {
        guard
            let url = AnyURL(string: href),
            var link = publication.linkWithHREF(url)
        else {
            log(.warning, "Cannot find link with HREF: \(href)")
            return
        }
        link.href = href

        Task {
            // Check to see if this was a noteref link and give delegate the
            // opportunity to display it.
            if
                let clickEvent = clickEvent,
                let interactive = clickEvent.interactiveElement,
                let (note, referrer) = await getNoteData(anchor: interactive, href: href),
                let delegate = delegate
            {
                if !delegate.navigator(
                    self,
                    shouldNavigateToNoteAt: link,
                    content: note,
                    referrer: referrer
                ) {
                    return
                }
            }

            // Ask if we should navigate to the link
            if let delegate = delegate, !delegate.navigator(self, shouldNavigateToLink: link) {
                return
            }

            await go(to: link)
        }
    }

    /// Checks if the internal link is a noteref, and retrieves both the referring text of the link and the body of the note.
    ///
    /// Uses the navigation href from didTapOnInternalLink because it is normalized to a path within the book,
    /// whereas the anchor tag may have just a hash fragment like `#abc123` which is hard to work with.
    /// We do at least validate to ensure that the two hrefs match.
    ///
    /// Uses `#id` when retrieving the body of the note, not `aside#id` because it may be a `<section>`.
    /// See https://idpf.github.io/epub-vocabs/structure/#footnotes
    /// and http://kb.daisy.org/publishing/docs/html/epub-type.html#ex
    func getNoteData(anchor: String, href: String) async -> (String, String)? {
        do {
            let doc = try parse(anchor)
            guard let link = try doc.select("a[epub:type=noteref]").first() else { return nil }

            let anchorHref = try link.attr("href")
            guard href.hasSuffix(anchorHref) else { return nil }

            guard
                let url = AnyURL(string: href),
                let id = url.fragment
            else {
                log(.warning, "Could not find hash in link \(href)")
                return nil
            }

            // Read the note's resource through the publication's resource API.
            guard let resource = publication.get(url.removingFragment()) else {
                log(.warning, "Could not open note resource: \(href)")
                return nil
            }
            let contents = try await resource.read().asString().get()
            let document = try parse(contents)

            guard let aside = try document.select("#\(id)").first() else {
                log(.warning, "Could not find the element '#\(id)' in document \(href)")
                return nil
            }

            return try (aside.html(), link.html())

        } catch {
            log(.warning, "Caught error while getting note content: \(error)")
            return nil
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, didActivateDecoration id: Decoration.Id, inGroup group: DecorationGroup, frame: CGRect?, point: CGPoint?) {
        guard
            let callbacks = decorationCallbacks[group].takeIf({ !$0.isEmpty }),
            let decoration: Decoration = decorations[group]?
            .first(where: { $0.decoration.id == id })
            .map(\.decoration)
        else {
            return
        }

        for callback in callbacks {
            callback(OnDecorationActivatedEvent(decoration: decoration, group: group, rect: frame, point: point))
        }
    }

    func spreadView(_ spreadView: EPUBSpreadView, selectionDidChange text: Locator.Text?, frame: CGRect) {
        guard
            let locator = currentLocation,
            let text = text
        else {
            viewModel.editingActions.selection = nil
            return
        }
        viewModel.editingActions.selection = Selection(
            locator: locator.copy(text: { $0 = text }),
            frame: frame
        )
    }

    func spreadViewPagesDidChange(_ spreadView: EPUBSpreadView) {
        if viewModel.continuousScroll {
            scheduleContinuousPageRemeasure(for: spreadView)
            return
        }
        if paginationView?.currentView == spreadView {
            updateCurrentLocation()
        }
    }

    private func scheduleContinuousPageRemeasure(for spreadView: EPUBSpreadView) {
        pendingContinuousPageRemeasureSpreads[ObjectIdentifier(spreadView)] = spreadView
        guard continuousPageRemeasureTask == nil else { return }

        let generation = continuousPageRemeasureGeneration
        let token = UUID()
        continuousPageRemeasureToken = token
        continuousPageRemeasureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  generation == self.continuousPageRemeasureGeneration,
                  let (id, spreadView) = self.pendingContinuousPageRemeasureSpreads.first {
                self.pendingContinuousPageRemeasureSpreads.removeValue(forKey: id)
                guard let paginationView = self.paginationView,
                      let continuousView = spreadView as? ContinuousPageView,
                      let index = paginationView.loadedViews.first(
                          where: { $0.value === spreadView }
                      )?.key else { continue }

                _ = await continuousView.prepareForContinuousLayout(
                    viewportSize: paginationView.bounds.size
                )
                guard !Task.isCancelled,
                      generation == self.continuousPageRemeasureGeneration,
                      paginationView.loadedViews[index] === spreadView else { continue }
                paginationView.updateContinuousPageHeight(
                    at: index,
                    height: continuousView.continuousContentHeight
                )
                self.updateCurrentLocation()
            }
            if self.continuousPageRemeasureToken == token {
                self.continuousPageRemeasureToken = nil
                self.continuousPageRemeasureTask = nil
            }
        }
    }

    private func cancelContinuousPageRemeasure() {
        continuousPageRemeasureGeneration &+= 1
        pendingContinuousPageRemeasureSpreads.removeAll()
        continuousPageRemeasureToken = nil
        continuousPageRemeasureTask?.cancel()
        continuousPageRemeasureTask = nil
    }

    func spreadView(_ spreadView: EPUBSpreadView, present viewController: UIViewController) {
        present(viewController, animated: true)
    }

    func spreadViewDidTerminate() {
        reloadSpreads()
    }
}

extension EPUBNavigatorViewController: EditingActionsControllerDelegate {
    func editingActionsDidPreventCopy(_ editingActions: EditingActionsController) {
        delegate?.navigator(self, presentError: .copyForbidden)
    }

    func editingActions(_ editingActions: EditingActionsController, shouldShowMenuForSelection selection: Selection) -> Bool {
        delegate?.navigator(self, shouldShowMenuForSelection: selection) ?? true
    }

    func editingActions(_ editingActions: EditingActionsController, canPerformAction action: EditingAction, for selection: Selection) -> Bool {
        delegate?.navigator(self, canPerformAction: action, for: selection) ?? true
    }
}

extension EPUBNavigatorViewController: PaginationViewDelegate {
    private func configuredUserScripts() -> [WKUserScript] {
        let userContentController = WKUserContentController()
        delegate?.navigator(self, setupUserScripts: userContentController)
        return userContentController.userScripts
    }

    private func makeSpreadView(for spread: EPUBSpread, receivesNavigatorEvents: Bool) -> EPUBSpreadView {
        let scripts = configuredUserScripts()
        let spreadView: EPUBSpreadView
        if publication.metadata.layout == .fixed {
            spreadView = EPUBFixedSpreadView(
                viewModel: viewModel,
                spread: spread,
                scripts: scripts,
                animatedLoad: false
            )
        } else {
            spreadView = EPUBReflowableSpreadView(
                viewModel: viewModel,
                spread: spread,
                scripts: scripts,
                animatedLoad: false
            )
        }

        if receivesNavigatorEvents {
            spreadView.delegate = self
        }
        spreadView.isUserPageTurnInteractionEnabled =
            receivesNavigatorEvents && isUserPageTurnInteractionEnabled

        return spreadView
    }

    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)? {
        let spread = spreads[index]
        return makeSpreadView(for: spread, receivesNavigatorEvents: true)
    }

    func paginationViewDidUpdateViews(_ paginationView: PaginationView) {
        // Note that you should set the delegate before you load views
        // otherwise, when open the publication, you may miss the first
        // invocation.
        updateCurrentLocation()
    }

    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int {
        spreads[index].positionCount(in: readingOrder, positionsByReadingOrder: positionsByReadingOrder)
    }
}
