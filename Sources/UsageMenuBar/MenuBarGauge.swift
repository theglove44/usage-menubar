import AppKit
import SwiftUI

// The menu bar gauge: ten small blocks, one per 10% of the chosen provider's
// quota used. Green while there is plenty left, amber when it is getting tight,
// red near the limit.

let menuBarSegmentCount = 10

func menuBarFilledSegments(pct: Double?) -> Int {
    guard let pct else { return 0 }
    let clamped = min(max(pct, 0), 100)
    if clamped == 0 { return 0 }
    // Round up any non-zero usage to one block, so "barely used" still reads
    // differently from "no data".
    return max(1, Int((clamped / 100 * Double(menuBarSegmentCount)).rounded()))
}

func menuBarSegmentColor(pct: Double?) -> Color {
    guard let pct else { return Color.gray }
    switch pct {
    case ..<75: return Color(red: 0.20, green: 0.78, blue: 0.35)
    case ..<90: return Color(red: 0.98, green: 0.72, blue: 0.15)
    default: return Color(red: 0.95, green: 0.27, blue: 0.24)
    }
}

func menuBarLabelText(provider: MenuBarProvider, pct: Double?) -> String {
    guard let pct else { return "\(provider.displayName) --" }
    return "\(provider.displayName) \(Int(pct.rounded()))%"
}

struct MenuBarGauge: View {
    let pct: Double?

    var body: some View {
        let filled = menuBarFilledSegments(pct: pct)
        let fill = menuBarSegmentColor(pct: pct)
        HStack(spacing: 1.5) {
            ForEach(0..<menuBarSegmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < filled ? fill : Color.gray.opacity(0.35))
                    .frame(width: 3, height: 11)
            }
        }
        .padding(.vertical, 1)
    }
}

// A MenuBarExtra label only reliably renders Text and Image, not arbitrary
// SwiftUI shapes, so the gauge is drawn once into a bitmap per refresh.
@MainActor
func renderMenuBarGauge(pct: Double?) -> NSImage? {
    let renderer = ImageRenderer(content: MenuBarGauge(pct: pct))
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    guard let image = renderer.nsImage else { return nil }
    // Not a template image: template images get recoloured to match the menu
    // bar, which would throw away the green/amber/red signal.
    image.isTemplate = false
    return image
}
