import SwiftUI

/// A tiny line chart of recent usage samples (0…1, oldest→newest), with a soft
/// gradient fill underneath. Used in the expanded provider detail.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.accentWarm

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count >= 2 {
                    // Gradient fill under the line.
                    fillPath(pts, in: geo.size)
                        .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.0)],
                                             startPoint: .top, endPoint: .bottom))
                    // The line itself.
                    linePath(pts)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    // Leading dot at the latest sample.
                    if let last = pts.last {
                        Circle().fill(color).frame(width: 4, height: 4).position(last)
                    }
                } else {
                    Text("Collecting history…")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let n = values.count
        let stepX = size.width / CGFloat(n - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * stepX,
                    y: size.height * (1 - CGFloat(max(0, min(1, v)))))
        }
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        return p
    }

    private func fillPath(_ pts: [CGPoint], in size: CGSize) -> Path {
        var p = linePath(pts)
        p.addLine(to: CGPoint(x: pts.last!.x, y: size.height))
        p.addLine(to: CGPoint(x: pts.first!.x, y: size.height))
        p.closeSubpath()
        return p
    }
}
