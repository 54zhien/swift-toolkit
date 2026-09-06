//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared
import UIKit

/// A direction relative to the publication's reading progression.
public enum NavigatorPageDirection: Hashable, Sendable {
    case forward
    case backward
}

/// A stable, detached representation of a page prepared for a transition.
///
/// The view is a snapshot and is safe for a client to place in its own
/// transition container. It is only a visual surface; the navigator remains
/// the source of truth for the publication location.
@MainActor public final class NavigatorPageSurface {
    public let direction: NavigatorPageDirection
    public let locator: Locator
    public let view: UIView

    /// Whether `view` is detached from the navigator and can be animated by a
    /// client without changing navigator state.
    public let isSnapshot: Bool = true

    let token: UUID
    let origin: Locator
    let generation: Int
    private(set) var isValid = true

    init(
        direction: NavigatorPageDirection,
        locator: Locator,
        view: UIView,
        origin: Locator,
        token: UUID,
        generation: Int
    ) {
        self.direction = direction
        self.locator = locator
        self.view = view
        self.origin = origin
        self.token = token
        self.generation = generation
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.isAccessibilityElement = false
    }

    func invalidate() {
        isValid = false
    }
}

/// Provides a prepared neighboring page and a transactional, settled commit.
///
/// Prewarming may use an off-screen navigation transaction, but must restore
/// the origin before it returns. Taking a prepared surface for a gesture is
/// synchronous from the navigator's point of view: it must not navigate,
/// layout, or snapshot. A prepared surface is single-use: after it is
/// committed, cancelled, or invalidated by another navigation it must not be
/// reused.
@MainActor public protocol AdjacentPageSurfaceProviding: AnyObject {
    /// Warms the detached previous/next surfaces while the navigator is idle.
    ///
    /// The operation may temporarily navigate an off-screen navigator and
    /// restore its original locator, but it must complete before a gesture
    /// starts. Implementations must preserve the original locator on failure
    /// or cancellation.
    func prewarmAdjacentPageSurfaces() async

    /// Invalidates all prepared surfaces and bumps their generation.
    /// Call this after a settings, size, theme or external navigation change.
    func invalidateAdjacentPageSurfaces()

    func prepareAdjacentPage(direction: NavigatorPageDirection) async -> NavigatorPageSurface?

    /// Commits the prepared surface without an additional navigator animation.
    /// The returned value is `true` only after the navigator has settled at the
    /// surface's target location.
    @discardableResult
    func commitAdjacentPage(_ surface: NavigatorPageSurface) async -> Bool

    /// Invalidates a prepared surface without changing the current location.
    func cancelAdjacentPage(_ surface: NavigatorPageSurface)
}
