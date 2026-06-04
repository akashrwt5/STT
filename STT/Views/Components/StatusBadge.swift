// StatusBadge.swift
// STT

import SwiftUI

/// Pill-shaped badge showing the active audio input source with a live indicator.
struct StatusBadge: View {
    let source: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
                .overlay {
                    if isActive {
                        Circle()
                            .fill(Color.green.opacity(0.4))
                            .frame(width: 14, height: 14)
                            .scaleEffect(isActive ? 1.0 : 0.5)
                            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isActive)
                    }
                }

            Text(sourceIcon + " " + source)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
        .accessibilityLabel("Audio source: \(source), \(isActive ? "active" : "inactive")")
    }

    private var sourceIcon: String {
        if source.lowercased().contains("bluetooth") || source.lowercased().contains("hearing") {
            return "🦻"
        } else if source.lowercased().contains("headphone") || source.lowercased().contains("airpod") {
            return "🎧"
        } else {
            return "🎙"
        }
    }
}

#Preview {
    ZStack {
        Color.black
        VStack(spacing: 12) {
            StatusBadge(source: "iPhone Mic", isActive: true)
            StatusBadge(source: "Hearing Aid", isActive: false)
        }
    }
}
