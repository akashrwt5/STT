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

            if let intent = result.intentResult {
                intentBadge(intent)
            }

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

    // MARK: - Intent badge

    @ViewBuilder
    private func intentBadge(_ intent: IntentResult) -> some View {
        switch intent {
        case .intent(let label, let confidence):
            HStack(spacing: 6) {
                Image(systemName: intent.systemImage)
                Text(intent.displayLabel)
                    .fontWeight(.semibold)
                Spacer()
                Text(String(format: "%.0f%%", confidence * 100))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .font(.system(size: 12))
            .foregroundStyle(intentColor(for: label))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(intentColor(for: label).opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(intentColor(for: label).opacity(0.3), lineWidth: 0.5)
            )

        case .genai(let url, let confidence):
            Link(destination: url) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                    Text("Unknown — Ask AI")
                        .fontWeight(.medium)
                    Spacer()
                    Text(String(format: "%.0f%%", confidence * 100))
                        .foregroundStyle(.white.opacity(0.5))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                }
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 1.0))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(red: 0.3, green: 0.3, blue: 0.8).opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(red: 0.4, green: 0.4, blue: 0.9).opacity(0.3), lineWidth: 0.5)
                )
            }
        }
    }

    private func intentColor(for label: String) -> Color {
        switch label {
        case "REMINDER":                          return Color(red: 1.0, green: 0.75, blue: 0.2)
        case "VOLUME_INCREASE", "VOLUME_UNMUTE":  return Color(red: 0.2, green: 0.8, blue: 0.6)
        case "VOLUME_DECREASE", "VOLUME_MUTE":    return Color(red: 0.4, green: 0.7, blue: 0.9)
        case "NOTIFICATIONS":                     return Color(red: 0.4, green: 0.7, blue: 1.0)
        case "MEMORY":                            return Color(red: 0.9, green: 0.4, blue: 0.8)
        case "PUSH_TO_TALK":                      return Color(red: 0.3, green: 0.9, blue: 0.4)
        case "SELFCHECK":                         return Color(red: 0.2, green: 0.9, blue: 0.9)
        case "TRANSLATE":                         return Color(red: 1.0, green: 0.5, blue: 0.3)
        case "TRANSCRIBE":                        return Color(red: 0.6, green: 0.8, blue: 1.0)
        case "TELEHEARAI":                        return Color(red: 0.8, green: 0.5, blue: 1.0)
        case "ACTIVITY":                          return Color(red: 0.5, green: 1.0, blue: 0.5)
        case "BATTERY":                           return Color(red: 0.4, green: 0.9, blue: 0.3)
        case "FIND_MY_PHONE":                     return Color(red: 0.3, green: 0.8, blue: 1.0)
        case "HELP":                              return Color(red: 1.0, green: 0.8, blue: 0.4)
        case "LISTEN_MESSAGE":                    return Color(red: 0.7, green: 0.5, blue: 1.0)
        case "OUT_OF_SCOPE":                      return Color(red: 0.6, green: 0.6, blue: 0.6)
        default:                                  return .white
        }
    }
}

#Preview {
    ZStack {
        Color(red: 0.04, green: 0.04, blue: 0.06)
        VStack(spacing: 12) {
            TranscriptionResultCard(result: {
                var r = TranscriptionResult(
                    text: "Turn the volume up",
                    isFinal: true,
                    locale: Locale(identifier: "en-IN"),
                    audioDuration: 1.8,
                    confidence: 0.95
                )
                r.intentResult = .intent(label: "VOLUME_INCREASE", confidence: 0.93)
                return r
            }())
            TranscriptionResultCard(result: {
                var r = TranscriptionResult(
                    text: "What is the weather today",
                    isFinal: true,
                    locale: Locale(identifier: "en-IN"),
                    audioDuration: 2.1,
                    confidence: 0.88
                )
                r.intentResult = .genai(
                    url: URL(string: "https://genai.yourcompany.com/chat?query=What+is+the+weather+today")!,
                    confidence: 0.31
                )
                return r
            }())
            TranscriptionResultCard(result: {
                var r = TranscriptionResult(
                    text: "Set a reminder for tomorrow",
                    isFinal: true,
                    locale: Locale(identifier: "en-IN"),
                    audioDuration: 2.4,
                    confidence: 0.97
                )
                r.intentResult = .intent(label: "REMINDER", confidence: 0.97)
                return r
            }())
        }
        .padding()
    }
}
