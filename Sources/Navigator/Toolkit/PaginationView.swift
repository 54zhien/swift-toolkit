//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import ReadiumShared
import UIKit

enum PageLocation: Equatable {
    case start
    case end
    case locator(Locator)

    init(_ locator: Locator?) {
        self = locator.map { .locator($0) }
            ?? .start
    }

    var isStart: Bool {
        switch self {
        case .start:
            return true
        case let .locator(locator) where locator.locations.progression ?? 0 == 0:
            return true
        default:
            return false
        }
    }
}

protocol PageView {
    /// Moves the page to the given internal location.
    func go(to location: PageLocation, animated: Bool) async
}

/// A page view which can participate in a publication-wide vertical scroll.
///
/// Continuous pages are laid out at their complete document height and the
/// outer pagination view owns the only user-facing scroll position. The
/// protocol is intentionally small so that fixed-layout and legacy page views
/// keep using the existing horizontal pagination path unchanged.
protocol ContinuousPageView: PageView {
    /// The measured document height, including any native content margins.
    var continuousContentHeight: CGFloat { get }

    /// Measures the document and transfers the current internal position into
    /// a resource-local progression. The returned progression is used when
    /// placing the page in the outer scroll view.
    func prepareForContinuousLayout(viewportSize: CGSize) async -> Double

    /// The latest resource-local progression after a programmatic navigation.
    var continuousProgression: Double { get }
}

protocol PaginationViewDelegate: AnyObject {
    /// Creates the page view for the page at given index.
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int) -> (UIView & PageView)?

    /// Called when the page views were updated.
    func paginationViewDidUpdateViews(_ paginationView: PaginationView)

    /// Returns the number of positions (as in `Publication.positionList`) in the page view at given index.
    func paginationView(_ paginationView: PaginationView, positionCountAtIndex index: Int) -> Int
}

final class PaginationView: UIView, Loggable {
    private static let continuousPreloadPreviousResourceCount = 1
    private static let continuousPreloadNextResourceCount = 2

    enum LayoutMode: Equatable {
        case horizontal
        case verticalContinuous
    }

    weak var delegate: PaginationViewDelegate?

    /// Total number of page views to be paginated.
    private(set) var pageCount: Int = 0

    /// Index of the page currently being displayed.
    private(set) var currentIndex: Int = 0

    /// Direction for the reading progression.
    private(set) var readingProgression: ReadingProgression = .ltr

    /// Pre-loaded page views, indexed by their position.
    private(set) var loadedViews: [Int: UIView & PageView] = [:]

    /// Number of positions (as in `Publication.positionList`) to preload before and after the
    /// current page.
    private let preloadPreviousPositionCount: Int
    private let preloadNextPositionCount: Int
    private(set) var layoutMode: LayoutMode

    /// Queue of page index to be loaded next.
    private var loadingIndexQueue: [(index: Int, location: PageLocation)] = []

    /// Returns whether the page views are loaded.
    var isEmpty: Bool {
        loadedViews.isEmpty
    }

    /// Return the currently presented page view from the Views array.
    var currentView: (UIView & PageView)? {
        loadedViews[currentIndex]
    }

    /// Loaded pages whose frames intersect the outer viewport. Used by the
    /// EPUB navigator to compute a publication-wide viewport in continuous
    /// mode without exposing the backing UIScrollView.
    var visiblePageViews: [(index: Int, view: UIView & PageView)] {
        guard layoutMode == .verticalContinuous else {
            guard let currentView else { return [] }
            return [(index: currentIndex, view: currentView)]
        }

        let visibleRect = CGRect(
            origin: scrollView.contentOffset,
            size: scrollView.bounds.size
        )
        return loadedViews
            .filter { $0.value.frame.intersects(visibleRect) }
            .sorted { $0.key < $1.key }
            .map { (index: $0.key, view: $0.value) }
    }

    var visibleContentRect: CGRect {
        CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
    }

    func pageFrame(for index: Int) -> CGRect? {
        guard 0 ..< pageCount ~= index else { return nil }
        switch layoutMode {
        case .horizontal:
            return CGRect(
                x: xOffsetForIndex(index),
                y: 0,
                width: scrollView.bounds.width,
                height: scrollView.bounds.height
            )
        case .verticalContinuous:
            let size = scrollView.bounds.size
            return CGRect(
                x: 0,
                y: yOffsetForIndex(index, viewportHeight: size.height),
                width: size.width,
                height: pageHeight(for: index, viewportHeight: size.height)
            )
        }
    }

    /// Loaded page views in reading order.
    private var orderedViews: [UIView & PageView] {
        var orderedViews = loadedViews
            .sorted { $0.key < $1.key }
            .map(\.value)

        if readingProgression == .rtl {
            orderedViews.reverse()
        }

        return orderedViews
    }

    private let scrollView = UIScrollView()
    private var pageHeights: [Int: CGFloat] = [:]
    private var pendingContinuousProgression: Double?
    private var shouldApplyLoadedContinuousProgression = false
    private var isLayingOut = false
    private var continuousLocationUpdateTask: Task<Void, Never>?

    /// Set while a transition animation is in progress to prevent
    /// `layoutSubviews` from resetting `contentOffset` and interrupting the
    /// animation.
    private var isAnimatingContentOffset = false

    /// Allows the scroll view to scroll.
    var isScrollEnabled: Bool {
        didSet { scrollView.isScrollEnabled = isScrollEnabled }
    }

    init(
        frame: CGRect,
        preloadPreviousPositionCount: Int,
        preloadNextPositionCount: Int,
        isScrollEnabled: Bool,
        layoutMode: LayoutMode = .horizontal
    ) {
        self.preloadPreviousPositionCount = preloadPreviousPositionCount
        self.preloadNextPositionCount = preloadNextPositionCount
        self.isScrollEnabled = isScrollEnabled
        self.layoutMode = layoutMode

        super.init(frame: frame)

        scrollView.delegate = self
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        scrollView.isPagingEnabled = true
        scrollView.bounces = false
        scrollView.alwaysBounceVertical = layoutMode == .verticalContinuous
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isScrollEnabled = isScrollEnabled
        addSubview(scrollView)

        // Adds an empty view before the scroll view to have a consistent behavior on all iOS
        // versions, regarding to the content inset adjustements. Even if
        // `automaticallyAdjustsScrollViewInsets` is not set to false on the navigator's parent
        // view controller, the scroll view insets won't be adjusted if the scroll view is not the
        // first child in the subviews hierarchy.
        insertSubview(UIView(frame: .zero), at: 0)
        // Prevents the content from jumping down when the status bar is toggled
        scrollView.contentInsetAdjustmentBehavior = .never
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        guard !loadedViews.isEmpty else {
            scrollView.contentSize = bounds.size
            return
        }

        let size = scrollView.bounds.size
        isLayingOut = true
        defer { isLayingOut = false }

        switch layoutMode {
        case .horizontal:
            scrollView.contentSize = CGSize(width: size.width * CGFloat(pageCount), height: size.height)

            for (index, view) in loadedViews {
                view.frame = CGRect(origin: CGPoint(x: xOffsetForIndex(index), y: 0), size: size)
            }

            if !isAnimatingContentOffset {
                scrollView.contentOffset.x = xOffsetForIndex(currentIndex)
            }

        case .verticalContinuous:
            let contentHeight = (0..<pageCount).reduce(CGFloat.zero) { partial, index in
                partial + pageHeight(for: index, viewportHeight: size.height)
            }
            scrollView.contentSize = CGSize(width: size.width, height: max(contentHeight, size.height))

            for (index, view) in loadedViews {
                let height = pageHeight(for: index, viewportHeight: size.height)
                view.frame = CGRect(
                    x: 0,
                    y: yOffsetForIndex(index, viewportHeight: size.height),
                    width: size.width,
                    height: height
                )
            }

            if let progression = pendingContinuousProgression,
               let view = loadedViews[currentIndex] as? ContinuousPageView {
                pendingContinuousProgression = nil
                let origin = yOffsetForIndex(currentIndex, viewportHeight: size.height)
                let range = max(view.continuousContentHeight - size.height, 0)
                scrollView.contentOffset.y = origin + CGFloat(progression.clamped(to: 0 ... 1)) * range
            }
        }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)

        if newSuperview == nil {
            cancelContinuousLocationUpdate()
            // Remove all spread views to break retain cycles
            for (_, view) in loadedViews {
                view.removeFromSuperview()
            }
            loadedViews.removeAll()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if window == nil {
            loadPagesTask.cancel()
        } else {
            loadPages()
        }
    }

    /// Returns the x offset to the page view with given index in the scroll view.
    private func xOffsetForIndex(_ index: Int) -> CGFloat {
        (readingProgression == .rtl)
            ? scrollView.contentSize.width - (CGFloat(index + 1) * scrollView.bounds.width)
            : scrollView.bounds.width * CGFloat(index)
    }

    /// Reloads the pagination with the given total number of pages and current index.
    ///
    /// - Parameters:
    ///   - index: Index of the page to be displayed after reloading the pagination.
    ///   - location: Location to be displayed in the page.
    ///   - pageCount: Total number of pages in the pagination view.
    ///   - readingProgression: Direction of reading progression.
    func reloadAtIndex(_ index: Int, location: PageLocation, pageCount: Int, readingProgression: ReadingProgression) {
        precondition(pageCount >= 1)
        precondition(0 ..< pageCount ~= index)
        cancelContinuousLocationUpdate()

        self.pageCount = pageCount
        self.readingProgression = readingProgression

        for (_, view) in loadedViews {
            view.removeFromSuperview()
        }
        loadedViews.removeAll()
        loadingIndexQueue.removeAll()
        pageHeights.removeAll()
        pendingContinuousProgression = locationProgression(location)
        shouldApplyLoadedContinuousProgression = true

        setCurrentIndex(index, location: location)
    }

    /// Changes the layout without changing the public pagination API. This is
    /// used when the EPUB scroll preference is submitted at runtime.
    func setLayoutMode(_ layoutMode: LayoutMode) {
        guard self.layoutMode != layoutMode else { return }
        cancelContinuousLocationUpdate()
        self.layoutMode = layoutMode
        scrollView.isPagingEnabled = layoutMode == .horizontal
        scrollView.alwaysBounceVertical = layoutMode == .verticalContinuous
        scrollView.alwaysBounceHorizontal = false
        setNeedsLayout()
    }

    /// Updates the current and pre-loaded views.
    private func setCurrentIndex(_ index: Int, location: PageLocation? = nil) {
        guard isEmpty || index != currentIndex else {
            return
        }

        // If no explicit location is given, we'll load either the beginning or the end of the
        // resource depending on the last index. This allows to navigate backward across resources,
        // starting from the end of each previous resource.
        let movingBackward = (currentIndex - 1 == index)
        let location = location ?? (movingBackward ? .end : .start)

        currentIndex = index

        // To make sure that the views the most likely to be visible are loaded first, we first load
        // the current one, then the next ones and to finish the previous ones.
        scheduleLoadPage(at: index, location: location)
        let lastIndex: Int
        let firstIndex: Int
        if layoutMode == .verticalContinuous {
            lastIndex = scheduleLoadResources(
                from: index,
                count: Self.continuousPreloadNextResourceCount,
                direction: .forward,
                location: .start
            )
            firstIndex = scheduleLoadResources(
                from: index,
                count: Self.continuousPreloadPreviousResourceCount,
                direction: .backward,
                location: .end
            )
        } else {
            lastIndex = scheduleLoadPages(from: index, upToPositionCount: preloadNextPositionCount, direction: .forward, location: .start)
            firstIndex = scheduleLoadPages(from: index, upToPositionCount: preloadPreviousPositionCount, direction: .backward, location: .end)
        }

        for (i, view) in loadedViews {
            // Flushes the views that are not needed anymore.
            guard firstIndex ... lastIndex ~= i else {
                view.removeFromSuperview()
                loadedViews.removeValue(forKey: i)
                continue
            }
        }

        loadPages()
    }

    private func loadPages() {
        loadPagesTask.replace { @MainActor in
            await loadNextPage()
            delegate?.paginationViewDidUpdateViews(self)
        }
    }

    private var loadPagesTask: Task<Void, Never>?

    private func loadNextPage() async {
        guard let (index, location) = loadingIndexQueue.popFirst() else {
            return
        }

        if
            loadedViews[index] == nil,
            let view = delegate?.paginationView(self, pageViewAtIndex: index)
        {
            loadedViews[index] = view
            scrollView.addSubview(view)
            setNeedsLayout()
        }

        guard let view = loadedViews[index] else {
            return
        }

        await view.go(to: location, animated: false)
        if layoutMode == .verticalContinuous,
           let view = view as? ContinuousPageView {
            let progression = await view.prepareForContinuousLayout(viewportSize: scrollView.bounds.size)
            updateContinuousPageHeight(at: index, height: view.continuousContentHeight)
            if index == currentIndex, shouldApplyLoadedContinuousProgression {
                pendingContinuousProgression = progression
                shouldApplyLoadedContinuousProgression = false
            }
        }
        await loadNextPage()
    }

    /// Updates the measured height of a loaded continuous page while keeping
    /// the current page's visible anchor stable.
    func updateContinuousPageHeight(at index: Int, height: CGFloat) {
        guard layoutMode == .verticalContinuous else { return }
        let anchorIndex = continuousIndex(at: scrollView.contentOffset.y)
        let oldOrigin = yOffsetForIndex(anchorIndex, viewportHeight: scrollView.bounds.height)
        let anchorOffset = scrollView.contentOffset.y - oldOrigin
        let resolvedHeight = max(height, scrollView.bounds.height)
        guard abs((pageHeights[index] ?? scrollView.bounds.height) - resolvedHeight) > 0.5 else {
            return
        }
        pageHeights[index] = resolvedHeight
        setNeedsLayout()
        layoutIfNeeded()

        guard index < anchorIndex else { return }
        let newOrigin = yOffsetForIndex(anchorIndex, viewportHeight: scrollView.bounds.height)
        if !isLayingOut {
            scrollView.contentOffset.y = newOrigin + anchorOffset
        }
    }

    private func locationProgression(_ location: PageLocation) -> Double? {
        switch location {
        case .start: return 0
        case .end: return 1
        case let .locator(locator): return locator.locations.progression
        }
    }

    private func pageHeight(for index: Int, viewportHeight: CGFloat) -> CGFloat {
        max(pageHeights[index] ?? viewportHeight, viewportHeight)
    }

    private func yOffsetForIndex(_ index: Int, viewportHeight: CGFloat) -> CGFloat {
        guard index > 0 else { return 0 }
        return (0..<index).reduce(CGFloat.zero) { partial, pageIndex in
            partial + pageHeight(for: pageIndex, viewportHeight: viewportHeight)
        }
    }

    private func continuousIndex(at offset: CGFloat) -> Int {
        guard pageCount > 1 else { return 0 }
        let value = max(offset, 0)
        var origin: CGFloat = 0
        for index in 0..<pageCount {
            let height = pageHeight(for: index, viewportHeight: scrollView.bounds.height)
            if value < origin + height { return index }
            origin += height
        }
        return pageCount - 1
    }

    /// Queue views to be loaded until reaching the given number of pre-loaded positions.
    ///
    /// - Parameters:
    ///   - positionCount: Number of positions to pre-load before stopping.
    ///   - sourceIndex: Starting page index from which to pre-load the views.
    ///   - direction: The direction in which to load the views from the sourceIndex.
    /// - Returns: The last page index to be loaded after reaching the requested number of positions.
    private func scheduleLoadPages(from sourceIndex: Int, upToPositionCount positionCount: Int, direction: PageIndexDirection, location: PageLocation) -> Int {
        let index = sourceIndex + direction.rawValue
        guard
            positionCount > 0,
            scheduleLoadPage(at: index, location: location),
            let indexPositionCount = delegate?.paginationView(self, positionCountAtIndex: index)
        else {
            return sourceIndex
        }

        return scheduleLoadPages(
            from: index,
            upToPositionCount: positionCount - indexPositionCount,
            direction: direction,
            location: location
        )
    }

    private func scheduleLoadResources(
        from sourceIndex: Int,
        count: Int,
        direction: PageIndexDirection,
        location: PageLocation
    ) -> Int {
        guard count > 0 else { return sourceIndex }
        let index = sourceIndex + direction.rawValue
        guard scheduleLoadPage(at: index, location: location) else { return sourceIndex }
        return scheduleLoadResources(from: index, count: count - 1, direction: direction, location: location)
    }

    /// Queue a page to be loaded at the given index, if it's not already loaded.
    ///
    /// - Returns: Whether page is or will be loaded.
    @discardableResult
    private func scheduleLoadPage(at index: Int, location: PageLocation) -> Bool {
        guard 0 ..< pageCount ~= index else {
            return false
        }

        loadingIndexQueue.removeAll { $0.index == index }
        loadingIndexQueue.append((index: index, location: location))
        return true
    }

    private enum PageIndexDirection: Int {
        case forward = 1
        case backward = -1
    }

    // MARK: - Navigation

    /// Go to the page view with given index.
    ///
    /// - Parameters:
    ///   - index: The index to move to.
    ///   - location: The location to move the future current page view to.
    /// - Returns: Whether the move is possible.
    func goToIndex(_ index: Int, location: PageLocation, options: NavigatorGoOptions) async -> Bool {
        guard 0 ..< pageCount ~= index else {
            return false
        }

        let shouldAnimate = options.animated && !UIAccessibility.isReduceMotionEnabled

        if layoutMode == .verticalContinuous {
            if currentIndex != index {
                shouldApplyLoadedContinuousProgression = true
                setCurrentIndex(index, location: location)
            } else if let view = currentView {
                await view.go(to: location, animated: false)
            }

            await loadPagesTask?.value

            guard let view = loadedViews[index] as? ContinuousPageView else {
                return true
            }
            let progression = view.continuousProgression
            pendingContinuousProgression = shouldAnimate ? nil : progression
            setNeedsLayout()
            layoutIfNeeded()
            if shouldAnimate {
                let target = CGPoint(
                    x: 0,
                    y: yOffsetForIndex(index, viewportHeight: scrollView.bounds.height)
                        + CGFloat(progression.clamped(to: 0 ... 1))
                        * max(view.continuousContentHeight - scrollView.bounds.height, 0)
                )
                isAnimatingContentOffset = true
                await animate(duration: 0.3) {
                    self.scrollView.contentOffset = target
                }
                isAnimatingContentOffset = false
                updateContinuousIndexAndLocation()
            }
            return true
        }

        if currentIndex == index {
            await scrollToView(at: index, location: location, animated: shouldAnimate)
        } else if abs(currentIndex - index) == 1 {
            await slideToView(at: index, location: location, animated: shouldAnimate)
        } else {
            await fadeToView(at: index, location: location, animated: shouldAnimate)
        }
        return true
    }

    private func slideToView(at index: Int, location: PageLocation, animated: Bool) async {
        let fromOffset = scrollView.contentOffset
        let targetOffset = CGPoint(x: xOffsetForIndex(index), y: fromOffset.y)
        let translationX = fromOffset.x - targetOffset.x

        // We use a snapshot of the current view for two reasons:
        //
        // 1. The current view might get flushed when calling
        //    `setCurrentIndex()`, but we want to keep it on the screen during
        //    the animation.
        // 2. A workaround for visual glitches, see https://github.com/readium/swift-toolkit/issues/737#issuecomment-4090386881
        let snapshot = snapshotView(afterScreenUpdates: false)
        if let snapshot {
            snapshot.frame = bounds
            addSubview(snapshot)
        } else {
            log(.warning, "Could not take a snapshot before sliding to view at index \(index); page transition may flash")
        }

        isAnimatingContentOffset = true
        scrollView.isScrollEnabled = false

        defer {
            snapshot?.removeFromSuperview()
            isAnimatingContentOffset = false
            scrollView.isScrollEnabled = isScrollEnabled
        }

        setCurrentIndex(index, location: location)

        scrollView.contentOffset = fromOffset

        if animated {
            await animate(duration: 0.3) {
                snapshot?.transform = CGAffineTransform(translationX: translationX, y: 0)
                self.scrollView.contentOffset = targetOffset
            }
        } else {
            scrollView.contentOffset = targetOffset
        }

        // There are visual glitches when scrolling web views into view.
        // To prevent these, we wait a few ms before removing the snapshot.
        // See https://github.com/readium/swift-toolkit/issues/737#issuecomment-4090386881
        if !animated {
            try? await Task.sleep(seconds: 0.1)
        }
    }

    private func fadeToView(at index: Int, location: PageLocation, animated: Bool) async {
        func fade(to alpha: CGFloat) async {
            await animate(duration: animated ? 0.15 : 0) {
                self.alpha = alpha
            }
        }

        await fade(to: 0)
        await scrollToView(at: index, location: location, animated: false)
        await fade(to: 1)
    }

    private func scrollToView(at index: Int, location: PageLocation, animated: Bool) async {
        guard currentIndex != index else {
            if let view = currentView {
                await view.go(to: location, animated: animated)
            }
            return
        }

        scrollView.isScrollEnabled = isScrollEnabled
        setCurrentIndex(index, location: location)

        scrollView.scrollRectToVisible(CGRect(
            origin: CGPoint(
                x: xOffsetForIndex(index),
                y: scrollView.contentOffset.y
            ),
            size: scrollView.frame.size
        ), animated: animated)
    }

    private func animate(duration: TimeInterval, animations: @escaping () -> Void) async {
        if duration > 0 {
            await withCheckedContinuation { continuation in
                UIView.animate(
                    withDuration: duration,
                    animations: animations,
                    completion: { _ in
                        continuation.resume()
                    }
                )
            }
        } else {
            animations()
        }
    }
}

extension PaginationView: UIScrollViewDelegate {
    // We disable the scroll once the user releases the drag to prevent scrolling through more than 1 resource at a
    // time. Otherwise, because the pagination view's scroll view would have the focus during the scroll gesture, the
    // scrollable content of the resources would be skipped.
    // Note: using this approach might provide a better experience:
    // https://oleb.net/blog/2014/05/scrollviews-inside-scrollviews/

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if layoutMode == .verticalContinuous {
            return
        }
        scrollView.isScrollEnabled = false
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if layoutMode == .verticalContinuous {
            updateContinuousIndexAndLocation()
            return
        }
        scrollView.isScrollEnabled = isScrollEnabled
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if layoutMode == .verticalContinuous {
            if !decelerate {
                updateContinuousIndexAndLocation()
            }
            return
        }
        if !decelerate {
            scrollView.isScrollEnabled = isScrollEnabled
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if layoutMode == .verticalContinuous {
            updateContinuousIndexAndLocation()
            return
        }
        // A programmatic slide animation sets isScrollEnabled = false and drives the
        // content offset directly. If a delegate callback fires during or just after
        // that window it could call setCurrentIndex with a stale offset, so we bail out.
        guard !isAnimatingContentOffset else { return }

        scrollView.isScrollEnabled = isScrollEnabled

        let currentOffset = (readingProgression == .rtl)
            ? scrollView.contentSize.width - (scrollView.contentOffset.x + scrollView.frame.width)
            : scrollView.contentOffset.x

        let newIndex = Int(round(currentOffset / scrollView.frame.width))
        setCurrentIndex(newIndex)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard layoutMode == .verticalContinuous, !isLayingOut, !isAnimatingContentOffset else { return }
        let newIndex = continuousIndex(at: scrollView.contentOffset.y)
        if newIndex != currentIndex {
            setCurrentIndex(newIndex)
        }
        scheduleContinuousLocationUpdate()
    }

    private func scheduleContinuousLocationUpdate() {
        guard continuousLocationUpdateTask == nil else { return }
        continuousLocationUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self, !Task.isCancelled else { return }
            self.continuousLocationUpdateTask = nil
            guard self.layoutMode == .verticalContinuous else { return }
            self.delegate?.paginationViewDidUpdateViews(self)
        }
    }

    private func updateContinuousIndexAndLocation() {
        cancelContinuousLocationUpdate()
        let newIndex = continuousIndex(at: scrollView.contentOffset.y)
        if newIndex != currentIndex {
            setCurrentIndex(newIndex)
        }
        delegate?.paginationViewDidUpdateViews(self)
    }

    private func cancelContinuousLocationUpdate() {
        continuousLocationUpdateTask?.cancel()
        continuousLocationUpdateTask = nil
    }
}
