// STTTestView.swift
// STT

import SwiftUI

/// Root test screen with tab switching between Live and File transcription modes.
struct STTTestView: View {
    @State private var selectedTab: Tab = .live
    @State private var showLanguagePicker = false
    @State private var showDiagnosticLog = false
    @State private var coordinator = TranscriptionCoordinator()

    enum Tab: String, CaseIterable {
        case live = "Live"
        case file = "File"

        var icon: String {
            switch self {
            case .live: return "mic.fill"
            case .file: return "waveform"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.04, green: 0.04, blue: 0.08).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                customTabBar
                tabContent
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLanguagePicker) {
            LanguageSelectorView(currentLocale: coordinator.currentLocale) { identifier in
                Task { try? await coordinator.switchLocale(to: identifier) }
            }
        }
        .sheet(isPresented: $showDiagnosticLog) {
            DiagnosticLogView()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speech Engine")
                    .font(.system(size: 28, weight: .bold, design: .default))
                    .foregroundStyle(.white)

                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: 0.2, green: 0.8, blue: 0.5))
                        .frame(width: 6, height: 6)
                    Text(headerSubtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    showDiagnosticLog = true
                } label: {
                    Image(systemName: "ladybug")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Open diagnostic log exporter")

                Button {
                    showLanguagePicker = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Open settings and language picker")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var headerSubtitle: String {
        let lang = Locale.current.localizedString(forIdentifier: coordinator.currentLocale.identifier)
            ?? coordinator.currentLocale.identifier
        let route = coordinator.currentRoute.name
        return "\(lang) · \(route)"
    }

    private var customTabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(duration: 0.3)) { selectedTab = tab }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.white.opacity(0.12))
                                .matchedGeometryEffect(id: "tab", in: tabNamespace)
                        }
                    }
                }
                .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @Namespace private var tabNamespace

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .live:
            LiveTranscriptionView(coordinator: coordinator)
                .transition(.asymmetric(
                    insertion: .move(edge: .leading),
                    removal: .move(edge: .leading)
                ))
        case .file:
            FileTranscriptionView(coordinator: coordinator)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing),
                    removal: .move(edge: .trailing)
                ))
        }
    }
}

#Preview {
    STTTestView()
}
