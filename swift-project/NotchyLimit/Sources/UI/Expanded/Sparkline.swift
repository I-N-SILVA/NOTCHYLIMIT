import SwiftUI

/// A compact 7-day usage trend for the active provider, drawn from
/// `UsageHistoryStore` (#22). Renders nothing until at least two samples exist,
/// so a fresh install shows no empty chart.
///
/// The vertical scale is fixed 0–100% (top = at limit) so the line honestly
/// reflects how close usage is to the ceiling rather than exaggerating small
/// wobbles.
struct Sparkline: View {
    @ObservedObject var appState: AppState

    private var values: [Double] {
        UsageHistoryStore.shared.points(for: appState.activeProviderId).map { $0.percent }
    }

    var body: some View {
        let pts = values
        if pts.count >= 2 {
            let color = appState.sessionStatus.color
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("7-day trend")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Text("\(Int(((pts.last ?? 0) * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(color)
                }
                ZStack {
                    SparkShape(values: pts, filled: true)
                        .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.0)],
                                             startPoint: .top, endPoint: .bottom))
                    SparkShape(values: pts, filled: false)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                .frame(height: 26)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 0.75)
                    )
            )
        }
    }
}

/// Draws a polyline (or a filled area) across the width of its rect for the
/// given 0...1 values, on a fixed 0–100% vertical scale.
private struct SparkShape: Shape {
    let values: [Double]
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count >= 2 else { return path }

        func point(_ i: Int) -> CGPoint {
            let x = rect.width * CGFloat(i) / CGFloat(values.count - 1)
            let clamped = min(max(values[i], 0), 1)
            let y = rect.height * (1 - CGFloat(clamped))
            return CGPoint(x: x, y: y)
        }

        path.move(to: point(0))
        for i in 1..<values.count { path.addLine(to: point(i)) }

        if filled {
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.closeSubpath()
        }
        return path
    }
}
