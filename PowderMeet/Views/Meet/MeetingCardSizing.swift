import SwiftUI

/// Heights are measured from vertically unconstrained card contents, never
/// inferred from font size, path length, or the number of warning rows.
nonisolated enum MeetingCardSizing {
    static func height(measurements: [Int: CGFloat], cardCount: Int) -> CGFloat {
        measurements.filter { index, height in
            index >= 0 && index < cardCount && height.isFinite && height > 0
        }.values.max().map(ceil) ?? 430 // Bootstrap only, not a content cap.
    }
}

struct MeetingCardHeightPreference: PreferenceKey {
    nonisolated static var defaultValue: [Int: CGFloat] { [:] }
    nonisolated static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    func measuredMeetingPage(index: Int) -> some View {
        fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: MeetingCardHeightPreference.self,
                                       value: [index: geometry.size.height])
            })
            .frame(maxHeight: .infinity, alignment: .top)
    }
}
