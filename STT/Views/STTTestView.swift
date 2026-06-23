// STTTestView.swift
// STT

import SwiftUI

/// Root test screen with tab switching between Live and File transcription modes.
struct STTTestView: View {
    @State private var selectedTab: Tab = .live
    @State private var showLanguagePicker = false
    @State private var coordinator: TranscriptionCoordinator
    @State private var liveViewModel: LiveTranscriptionViewModel

    init() {
        let c = TranscriptionCoordinator()
        _coordinator = State(initialValue: c)
        _liveViewModel = State(initialValue: LiveTranscriptionViewModel(coordinator: c))
    }

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

            // Diagnostic lifecycle buttons.
            //  IC+ / IC- : create or release the coordinator's diagnostic IntentClassifier
            //  S3+ / S3- : load or release Stage 3 (MiniLM) on the live NLU classifier
            // Each tap brackets the operation with MemoryProbe so the console
            // shows phys_footprint Δ. Combined with the [Deinit] logs on
            // IntentClassifierService / SemanticEmbedder / SemanticClassifier,
            // we can verify both deallocation AND memory reclaim.
            HStack(spacing: 4) {
                memoryLifecycleButton(title: "IC+", icon: "plus.circle") {
                    #if DEBUG
                    let before = MemoryProbe.snapshot(label: "before Init IC")
                    #endif
                    coordinator.initIntentClassifier()
                    #if DEBUG
                    let after = MemoryProbe.snapshot(label: "after Init IC")
                    MemoryProbe.logDiff(before: before, after: after)
                    #endif
                }
                memoryLifecycleButton(title: "IC-", icon: "minus.circle") {
                    #if DEBUG
                    let before = MemoryProbe.snapshot(label: "before Free IC")
                    #endif
                    coordinator.freeIntentClassifier()
                    #if DEBUG
                    let after = MemoryProbe.snapshot(label: "after Free IC")
                    MemoryProbe.logDiff(before: before, after: after)
                    #endif
                }
                memoryLifecycleButton(title: "S3+", icon: "arrow.down.to.line") {
                    #if DEBUG
                    let before = MemoryProbe.snapshot(label: "before Stage3 Load")
                    #endif
                    await liveViewModel.loadStage3()
                    #if DEBUG
                    let after = MemoryProbe.snapshot(label: "after Stage3 Load")
                    MemoryProbe.logDiff(before: before, after: after)
                    #endif
                }
                memoryLifecycleButton(title: "S3-", icon: "arrow.up.to.line") {
                    #if DEBUG
                    let before = MemoryProbe.snapshot(label: "before Stage3 Release")
                    #endif
                    await liveViewModel.releaseStage3()
                    #if DEBUG
                    let after = MemoryProbe.snapshot(label: "after Stage3 Release")
                    MemoryProbe.logDiff(before: before, after: after)
                    #endif
                }
            }

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
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func memoryLifecycleButton(
        title: String,
        icon: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.08), in: Capsule())
        }
        .accessibilityLabel("\(title) speech model")
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
            LiveTranscriptionView(viewModel: liveViewModel)
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
