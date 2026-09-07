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

/// The result of warming one side of the page-turn cache.
public enum NavigatorPageSurfaceReadiness: Equatable, Sendable {
    case unavailable
    case preparing
    case ready
    case failed
}

/// Outcome of committing a prepared page surface.
///
/// `indeterminate` means the navigator was neither proven to be back at the
/// origin nor proven to be at the target. Callers must reconcile the current
/// locator before removing any transition UI.
public enum NavigatorPageCommitResult: Equatable, Sendable {
    case committed
    case restored
    case indeterminate
}

/// Identity of an immutable page surface.
public struct NavigatorPageSurfaceIdentity: Hashable, Sendable {
    public let direction: NavigatorPageDirection
    public let locator: Locator
    public let epoch: UInt64
    /// The concrete publication resource represented by this surface. This
    /// is especially important for fixed-layout spreads containing two
    /// leaves.
    public let leafHREF: AnyURL?
    public let leafIndex: Int?

    public init(
        direction: NavigatorPageDirection,
        locator: Locator,
        epoch: UInt64,
        leafHREF: AnyURL? = nil,
        leafIndex: Int? = nil
    ) {
        self.direction = direction
        self.locator = locator
        self.epoch = epoch
        self.leafHREF = leafHREF
        self.leafIndex = leafIndex
    }
}

/// A stable, detached, immutable representation of a page prepared for a
/// transition. The image is captured before a gesture starts and never shares
/// a live WebKit layer with the navigator.
@MainActor public final class NavigatorPageSurface {
    public let direction: NavigatorPageDirection
    public let locator: Locator
    public let image: UIImage
    public let identity: NavigatorPageSurfaceIdentity
    public var leafHREF: AnyURL? { identity.leafHREF }
    public var leafIndex: Int? { identity.leafIndex }

    let token: UUID
    let origin: Locator
    let generation: Int
    private(set) var isValid = true

    init(
        direction: NavigatorPageDirection,
        locator: Locator,
        image: UIImage,
        origin: Locator,
        token: UUID,
        generation: Int,
        leafHREF: AnyURL? = nil,
        leafIndex: Int? = nil
    ) {
        self.direction = direction
        self.locator = locator
        self.image = image
        self.identity = NavigatorPageSurfaceIdentity(
            direction: direction,
            locator: locator,
            epoch: UInt64(max(generation, 0)),
            leafHREF: leafHREF,
            leafIndex: leafIndex
        )
        self.origin = origin
        self.token = token
        self.generation = generation
    }

    func invalidate() {
        isValid = false
    }
}

/// Provides a prepared neighboring page and a transactional, settled commit.
///
/// Prewarming is performed while the navigator is idle. It may use already
/// loaded off-screen spread views or a detached renderer, but it must never
/// navigate the visible navigator. Taking a prepared surface for a gesture is
/// synchronous: it does not navigate, layout, or snapshot. A prepared
/// surface is single-use.
@MainActor public protocol AdjacentPageSurfaceProviding: AnyObject {
    /// Warms the detached previous/next surfaces while the navigator is idle.
    ///
    /// The operation must leave the visible navigator at its original
    /// location, even when a direction is unavailable or fails to render.
    func prewarmAdjacentPageSurfaces() async

    /// Returns the latest cache state for a direction without starting work.
    func adjacentPageReadiness(direction: NavigatorPageDirection) -> NavigatorPageSurfaceReadiness

    /// Invalidates all prepared surfaces and bumps their generation.
    /// Call this after a settings, size, theme or external navigation change.
    func invalidateAdjacentPageSurfaces()

    /// Takes a prepared surface synchronously during a gesture.
    func takePreparedAdjacentPage(direction: NavigatorPageDirection) -> NavigatorPageSurface?

    /// Commits the prepared surface and reports whether the navigator settled
    /// at the target, was restored to the origin, or needs locator
    /// reconciliation before the transition UI is removed.
    @discardableResult
    func commitAdjacentPageResult(_ surface: NavigatorPageSurface) async -> NavigatorPageCommitResult

    /// Reconciles an indeterminate outcome until the absolute monotonic
    /// deadline. It never performs navigation.
    func reconcileAdjacentPageResult(
        _ surface: NavigatorPageSurface,
        deadline: UInt64
    ) async -> NavigatorPageCommitResult

    /// Invalidates a prepared surface without changing the current location.
    func cancelAdjacentPage(_ surface: NavigatorPageSurface)
}
