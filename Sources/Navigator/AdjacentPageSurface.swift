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

/// Point- and pixel-accurate geometry shared by every detached page image.
/// Consumers must reject a transition when the current and target geometry
/// differ instead of stretching either image to fit.
public struct NavigatorPageSurfaceGeometry: Equatable, Sendable {
    public let pointSize: CGSize
    public let pixelSize: CGSize
    public let scale: CGFloat
    public let contentRect: CGRect

    public init(image: UIImage, contentRect: CGRect) {
        pointSize = image.size
        if let cgImage = image.cgImage {
            pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else {
            pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        }
        scale = image.scale
        self.contentRect = contentRect
    }
}

/// The visible page captured by the same WebKit snapshot path as its
/// neighboring surfaces during prewarming.
@MainActor public final class NavigatorCurrentPageSurface {
    public let image: UIImage
    public let geometry: NavigatorPageSurfaceGeometry
    public let identity: NavigatorPagePositionIdentity
    public let generation: Int

    init(image: UIImage, contentRect: CGRect, identity: NavigatorPagePositionIdentity, generation: Int) {
        self.image = image
        geometry = NavigatorPageSurfaceGeometry(image: image, contentRect: contentRect)
        self.identity = identity
        self.generation = generation
    }
}

/// Direction-independent identity of the navigator position represented by a
/// surface. Adjacent surfaces bind their origin to the current surface with
/// this value before any animation is allowed to begin.
public struct NavigatorPagePositionIdentity: Hashable, Sendable {
    public let locator: Locator
    public let generation: Int

    public init(locator: Locator, generation: Int) {
        self.locator = locator
        self.generation = generation
    }
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
    public let geometry: NavigatorPageSurfaceGeometry
    public let identity: NavigatorPageSurfaceIdentity
    public let originIdentity: NavigatorPagePositionIdentity
    public var generation: Int { originIdentity.generation }
    public var leafHREF: AnyURL? { identity.leafHREF }
    public var leafIndex: Int? { identity.leafIndex }

    let token: UUID
    let origin: Locator
    private(set) var isValid = true

    init(
        direction: NavigatorPageDirection,
        locator: Locator,
        image: UIImage,
        origin: Locator,
        token: UUID,
        generation: Int,
        contentRect: CGRect,
        leafHREF: AnyURL? = nil,
        leafIndex: Int? = nil
    ) {
        self.direction = direction
        self.locator = locator
        self.image = image
        geometry = NavigatorPageSurfaceGeometry(image: image, contentRect: contentRect)
        self.identity = NavigatorPageSurfaceIdentity(
            direction: direction,
            locator: locator,
            epoch: UInt64(max(generation, 0)),
            leafHREF: leafHREF,
            leafIndex: leafIndex
        )
        self.origin = origin
        originIdentity = NavigatorPagePositionIdentity(locator: origin, generation: generation)
        self.token = token
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

    /// Returns the current page captured alongside the neighboring cache.
    /// This is synchronous so gesture handling never starts WebKit work.
    func preparedCurrentPageSurface() -> NavigatorCurrentPageSurface?

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
