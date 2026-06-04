// PulsingMicButton.swift
// STT

import SwiftUI

/// Animated microphone button with pulsing rings in listening state.
struct PulsingMicButton: View {
    var isListening: Bool
    var isProcessing: Bool = false
    var onTap: () -> Void

    @State private var pulseScale: CGFloat = 1.0
    @State private var isPressed: Bool = false

    var body: some View {
        ZStack {
            // Pulsing rings — only visible while listening
            if isListening {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(accentColor.opacity(0.3 - Double(index) * 0.08), lineWidth: 1.5)
                        .frame(width: 80 + CGFloat(index) * 28, height: 80 + CGFloat(index) * 28)
                        .scaleEffect(pulseScale)
                        .animation(
                            .easeOut(duration: 1.4)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.35),
                            value: pulseScale
                        )
                }
            }

            // Core button
            Circle()
                .fill(buttonGradient)
                .frame(width: 80, height: 80)
                .overlay {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: isListening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .scaleEffect(isPressed ? 0.93 : 1.0)
                .shadow(color: accentColor.opacity(0.5), radius: isListening ? 20 : 8, x: 0, y: 4)
        }
        .onAppear { pulseScale = 1.5 }
        .onTapGesture {
            withAnimation(.spring(duration: 0.1)) { isPressed = true }
            UIImpactFeedbackGenerator(style: isListening ? .medium : .light).impactOccurred()
            onTap()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(duration: 0.2)) { isPressed = false }
            }
        }
        .accessibilityLabel(isListening ? "Stop recording" : "Start recording")
        .accessibilityAddTraits(.isButton)
    }

    private var accentColor: Color {
        isListening ? Color(red: 1, green: 0.27, blue: 0.27) : Color(red: 0.2, green: 0.6, blue: 1)
    }

    private var buttonGradient: LinearGradient {
        LinearGradient(
            colors: isListening
                ? [Color(red: 1, green: 0.27, blue: 0.27), Color(red: 0.8, green: 0.1, blue: 0.1)]
                : [Color(red: 0.2, green: 0.6, blue: 1.0), Color(red: 0.1, green: 0.35, blue: 0.85)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#Preview {
    ZStack {
        Color(red: 0.04, green: 0.04, blue: 0.06)
        VStack(spacing: 40) {
            PulsingMicButton(isListening: false, onTap: {})
            PulsingMicButton(isListening: true, onTap: {})
        }
    }
}
