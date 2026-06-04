// AudioLevelBar.swift
// STT

import SwiftUI

/// Real-time horizontal audio level meter with animated bar segments.
struct AudioLevelBar: View {
    /// Normalized audio level in 0.0–1.0.
    var level: Float
    var barCount: Int = 30

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(for: index))
                    .frame(width: 3)
                    .frame(height: barHeight(for: index))
                    .animation(.spring(duration: 0.08), value: level)
            }
        }
        .frame(height: 40)
        .accessibilityLabel("Audio level indicator")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalizedIndex = Float(index) / Float(barCount - 1)
        let baseHeight: Float = 4
        let maxHeight: Float = 40
        let activeThreshold = level
        let heightScale = normalizedIndex <= activeThreshold
            ? (sin(normalizedIndex / activeThreshold * .pi) * 0.7 + 0.3)
            : 0.1

        return CGFloat(baseHeight + heightScale * (maxHeight - baseHeight))
    }

    private func barColor(for index: Int) -> Color {
        let normalizedIndex = Float(index) / Float(barCount - 1)
        if normalizedIndex <= level * 0.6 {
            return Color(hue: 0.54, saturation: 0.8, brightness: 0.9) // teal
        } else if normalizedIndex <= level {
            return Color(hue: 0.13, saturation: 0.9, brightness: 1.0) // amber
        } else {
            return .white.opacity(0.08)
        }
    }
}

#Preview {
    ZStack {
        Color(red: 0.04, green: 0.04, blue: 0.06)
        AudioLevelBar(level: 0.6)
            .padding()
    }
}
