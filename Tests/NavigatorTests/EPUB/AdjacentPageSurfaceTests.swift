//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing
import UIKit

@MainActor
struct AdjacentPageSurfaceTests {
    @Test("Adjacent surface preserves the prepared origin and generation")
    func preservesPreparedOrigin() {
        let origin = Locator(href: "chapter.html", mediaType: .html)
        let target = Locator(href: "chapter.html", mediaType: .html)
        let surface = makeSurface(origin: origin, target: target, generation: 42)

        #expect(surface.originIdentity.locator == origin)
        #expect(surface.originIdentity.generation == 42)
        #expect(surface.generation == 42)
        #expect(surface.identity.direction == .forward)
    }

    @Test("Consumed surface is invalidated without changing its identity")
    func invalidationIsSingleUse() {
        let surface = makeSurface(generation: 7)
        let identity = surface.identity

        #expect(surface.isValid)
        surface.invalidate()

        #expect(!surface.isValid)
        #expect(surface.identity == identity)
        #expect(surface.generation == 7)
    }

    @Test("Surface geometry retains point, pixel, scale and content rect")
    func preservesGeometry() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 120, height: 200),
            format: format
        ).image { _ in }
        let contentRect = CGRect(x: 8, y: 16, width: 104, height: 168)
        let surface = makeSurface(image: image, contentRect: contentRect)

        #expect(surface.geometry.pointSize == CGSize(width: 120, height: 200))
        #expect(surface.geometry.pixelSize == CGSize(width: 240, height: 400))
        #expect(surface.geometry.scale == 2)
        #expect(surface.geometry.contentRect == contentRect)
    }

    private func makeSurface(
        origin: Locator = Locator(href: "origin.html", mediaType: .html),
        target: Locator = Locator(href: "target.html", mediaType: .html),
        generation: Int = 1,
        image: UIImage = UIImage(),
        contentRect: CGRect = .zero
    ) -> NavigatorPageSurface {
        NavigatorPageSurface(
            direction: .forward,
            locator: target,
            image: image,
            origin: origin,
            token: UUID(),
            generation: generation,
            contentRect: contentRect
        )
    }
}
