// AudioVisualizerView.swift
// STT

import SwiftUI

/// Full-width audio waveform visualizer that responds to live audio levels.
struct AudioVisualizerView: View {
    var level: Float
    var isActive: Bool

    private let barCount = 40
    @State private var randomPhases: [Double] = (0..<40).map { _ in Double.random(in: 0..<2 * .pi) }
    @State private var animationOffset: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barGradient(at: index))
                    .frame(width: 3, height: barHeight(at: index))
                    .animation(.easeInOut(duration: 0.05), value: level)
            }
        }
        .frame(height: 60)
        .onAppear {
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                animationOffset = .pi * 2
            }
        }
        .accessibilityHidden(true)
    }

    private func barHeight(at index: Int) -> CGFloat {
        guard isActive else { return CGFloat.random(in: 2...4) }
        let phase = randomPhases[index] + animationOffset
        let sineComponent = CGFloat(sin(phase)) * 0.3
        let levelComponent = CGFloat(level) * 0.7
        let normalizedHeight = max(0.05, (sineComponent + levelComponent))
        return 4 + normalizedHeight * 56
    }

    private func barGradient(at index: Int) -> LinearGradient {
        let normalizedIndex = Double(index) / Double(barCount - 1)
        let hue = 0.54 + normalizedIndex * 0.1 // teal → blue
        let brightness = isActive ? 0.85 + Double(level) * 0.15 : 0.25
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.75, brightness: brightness),
                Color(hue: hue + 0.05, saturation: 0.6, brightness: brightness * 0.7)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#Preview {
    ZStack {
        Color(red: 0.04, green: 0.04, blue: 0.06)
        AudioVisualizerView(level: 0.6, isActive: true)
            .padding()
    }
}
