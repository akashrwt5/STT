// TranscriptionResultCard.swift
// STT

import SwiftUI

/// Glassmorphism card displaying a single final transcription result.
struct TranscriptionResultCard: View {
    let result: TranscriptionResult

    @State private var appeared = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(result.text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Label(Self.timeFormatter.string(from: result.timestamp), systemImage: "clock")
                Label(result.locale.identifier, systemImage: "globe")
                if let duration = result.audioDuration {
                    Label(String(format: "%.1fs", duration), systemImage: "waveform")
                }
                if let confidence = result.confidence {
                    Label(String(format: "%.0f%%", confidence * 100), systemImage: "checkmark.circle")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.1), lineWidth: 0.5)
        )
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .onAppear {
            withAnimation(.spring(duration: 0.35)) { appeared = true }
        }
    }
}

#Preview {
    ZStack {
        Color(red: 0.04, green: 0.04, blue: 0.06)
        TranscriptionResultCard(result: TranscriptionResult(
            text: "Volume up by 20 percent",
            isFinal: true,
            locale: Locale(identifier: "en-IN"),
            audioDuration: 2.4,
            confidence: 0.97
        ))
        .padding()
    }
}
