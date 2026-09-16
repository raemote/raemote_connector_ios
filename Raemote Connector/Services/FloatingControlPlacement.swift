import CoreGraphics
import Foundation
import SwiftUI

/// Which screen edge the floating control is anchored to.
enum ControlEdge: String, Codable, CaseIterable {
    case top
    case bottom
    case leading
    case trailing
}

/// Where the floating control sits: an edge plus a fraction along it
/// (`0…1`, top→bottom for a vertical edge, leading→trailing for a horizontal one).
///
/// Storing edge + fraction (rather than a point) keeps the control correctly
/// placed when the screen size or safe-area insets change, e.g. on rotation.
struct FloatingControlPlacement: Equatable, Codable {
    var edge: ControlEdge
    var fraction: CGFloat

    /// Bottom-right, which is where the control starts.
    static let `default` = FloatingControlPlacement(edge: .trailing, fraction: 0.82)

    /// Distance from the safe-area edge to the control's bounding box.
    static let margin: CGFloat = 10

    /// The control's center for a container of `size` and `safeInsets`.
    func center(in size: CGSize, safeInsets: EdgeInsets, diameter: CGFloat) -> CGPoint {
        let radius = diameter / 2
        let fraction = min(max(self.fraction, 0), 1)

        let minX = safeInsets.leading + Self.margin + radius
        let maxX = size.width - safeInsets.trailing - Self.margin - radius
        let minY = safeInsets.top + Self.margin + radius
        let maxY = size.height - safeInsets.bottom - Self.margin - radius

        switch edge {
        case .leading:
            return CGPoint(x: minX, y: lerp(minY, maxY, fraction))
        case .trailing:
            return CGPoint(x: maxX, y: lerp(minY, maxY, fraction))
        case .top:
            return CGPoint(x: lerp(minX, maxX, fraction), y: minY)
        case .bottom:
            return CGPoint(x: lerp(minX, maxX, fraction), y: maxY)
        }
    }

    /// Snap a free position to the nearest edge, clamped inside the safe area.
    static func snap(
        to point: CGPoint,
        in size: CGSize,
        safeInsets: EdgeInsets,
        diameter: CGFloat
    ) -> FloatingControlPlacement {
        let radius = diameter / 2
        let minX = safeInsets.leading + margin + radius
        let maxX = size.width - safeInsets.trailing - margin - radius
        let minY = safeInsets.top + margin + radius
        let maxY = size.height - safeInsets.bottom - margin - radius

        let x = clamp(point.x, minX, maxX)
        let y = clamp(point.y, minY, maxY)

        let candidates: [(ControlEdge, CGFloat)] = [
            (.leading, x - minX),
            (.trailing, maxX - x),
            (.top, y - minY),
            (.bottom, maxY - y),
        ]
        let edge = candidates.min(by: { $0.1 < $1.1 })?.0 ?? .trailing

        switch edge {
        case .leading, .trailing:
            return FloatingControlPlacement(edge: edge, fraction: fraction(of: y, from: minY, to: maxY))
        case .top, .bottom:
            return FloatingControlPlacement(edge: edge, fraction: fraction(of: x, from: minX, to: maxX))
        }
    }

    private static func fraction(of value: CGFloat, from lo: CGFloat, to hi: CGFloat) -> CGFloat {
        guard hi > lo else { return 0.5 }
        return clamp((value - lo) / (hi - lo), 0, 1)
    }
}

private func clamp(_ value: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    min(max(value, lo), max(lo, hi))
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * t
}

/// Persists the floating control's placement across launches.
enum FloatingControlStore {
    private static let key = "floatingControlPlacement"

    static func load(defaults: UserDefaults = .standard) -> FloatingControlPlacement {
        guard let data = defaults.data(forKey: key),
              let placement = try? JSONDecoder().decode(FloatingControlPlacement.self, from: data)
        else {
            return .default
        }
        return placement
    }

    static func save(_ placement: FloatingControlPlacement, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(placement) else { return }
        defaults.set(data, forKey: key)
    }
}
