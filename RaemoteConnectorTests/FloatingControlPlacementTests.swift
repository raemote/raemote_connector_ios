import Testing
import SwiftUI
@testable import Raemote_Connector

struct FloatingControlPlacementTests {
    private let size = CGSize(width: 800, height: 400)
    private let insets = EdgeInsets(top: 0, leading: 40, bottom: 20, trailing: 40)
    private let diameter: CGFloat = 52

    @Test func centerRespectsInsetsForEachEdge() {
        let margin = FloatingControlPlacement.margin
        let radius = diameter / 2

        let trailing = FloatingControlPlacement(edge: .trailing, fraction: 0.5)
            .center(in: size, safeInsets: insets, diameter: diameter)
        #expect(trailing.x == size.width - insets.trailing - margin - radius)

        let leading = FloatingControlPlacement(edge: .leading, fraction: 0.5)
            .center(in: size, safeInsets: insets, diameter: diameter)
        #expect(leading.x == insets.leading + margin + radius)

        let top = FloatingControlPlacement(edge: .top, fraction: 0.5)
            .center(in: size, safeInsets: insets, diameter: diameter)
        #expect(top.y == insets.top + margin + radius)

        let bottom = FloatingControlPlacement(edge: .bottom, fraction: 0.5)
            .center(in: size, safeInsets: insets, diameter: diameter)
        #expect(bottom.y == size.height - insets.bottom - margin - radius)
    }

    @Test func snapPicksNearestEdge() {
        func snap(_ x: CGFloat, _ y: CGFloat) -> ControlEdge {
            FloatingControlPlacement.snap(
                to: CGPoint(x: x, y: y),
                in: size,
                safeInsets: insets,
                diameter: diameter
            ).edge
        }
        #expect(snap(10, 200) == .leading)
        #expect(snap(790, 200) == .trailing)
        #expect(snap(400, 5) == .top)
        #expect(snap(400, 395) == .bottom)
    }

    @Test func snapClampsFraction() {
        let placement = FloatingControlPlacement.snap(
            to: CGPoint(x: 99999, y: 99999),
            in: size,
            safeInsets: insets,
            diameter: diameter
        )
        #expect(placement.fraction >= 0 && placement.fraction <= 1)
        // The center of the snapped placement must be inside the safe area.
        let center = placement.center(in: size, safeInsets: insets, diameter: diameter)
        #expect(center.x <= size.width - insets.trailing)
        #expect(center.y <= size.height - insets.bottom)
    }

    @Test func centerIsRotationSafe() {
        // Same placement, different (landscape→portrait) size.
        let placement = FloatingControlPlacement(edge: .trailing, fraction: 0)
        let landscape = placement.center(in: size, safeInsets: insets, diameter: diameter)
        let portrait = placement.center(
            in: CGSize(width: 400, height: 800),
            safeInsets: EdgeInsets(top: 40, leading: 0, bottom: 20, trailing: 0),
            diameter: diameter
        )
        #expect(landscape.y == insets.top + FloatingControlPlacement.margin + diameter / 2)
        #expect(portrait.x == 400 - 0 - FloatingControlPlacement.margin - diameter / 2)
    }

    @Test func storeRoundTrips() {
        let defaults = UserDefaults(suiteName: "FloatingControlPlacementTests-\(UUID().uuidString)")!
        #expect(FloatingControlStore.load(defaults: defaults) == .default)

        let custom = FloatingControlPlacement(edge: .top, fraction: 0.25)
        FloatingControlStore.save(custom, defaults: defaults)
        #expect(FloatingControlStore.load(defaults: defaults) == custom)
    }
}
