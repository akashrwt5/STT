// LanguageSelectorView.swift
// STT

import SwiftUI
import Speech

/// Bottom sheet for selecting the active transcription language.
struct LanguageSelectorView: View {
    @Environment(\.dismiss) private var dismiss

    let currentLocale: Locale
    let onSelect: (String) -> Void

    @State private var searchText = ""
    // Both loaded in .task — SpeechTranscriber APIs are async in iOS 26.
    @State private var locales: [Locale] = []
    @State private var autoLocale: Locale = Locale(identifier: "en-IN")
    @State private var autoLocaleDisplayName: String = "English (India)"

    private var filteredGroups: [(String, [Locale])] {
        let filtered = searchText.isEmpty ? locales : locales.filter { locale in
            let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            let native = locale.localizedString(forIdentifier: locale.identifier) ?? ""
            return name.localizedCaseInsensitiveContains(searchText)
                || native.localizedCaseInsensitiveContains(searchText)
        }
        return groupedLocales(from: filtered)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.06).ignoresSafeArea()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        Section {
                            autoDetectedRow
                        } header: {
                            sectionHeader("Automatic")
                        }

                        ForEach(filteredGroups, id: \.0) { group, localesInGroup in
                            Section {
                                ForEach(localesInGroup, id: \.identifier) { locale in
                                    localeRow(locale)
                                        .onTapGesture {
                                            UISelectionFeedbackGenerator().selectionChanged()
                                            onSelect(locale.identifier)
                                            dismiss()
                                        }
                                }
                            } header: {
                                sectionHeader(group)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Language")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 1.0))
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .task {
                // SpeechTranscriber APIs are async in iOS 26 — load after mount.
                async let fetchedLocales = SpeechTranscriber.supportedLocales
                async let fetchedAuto = SpeechRecognitionService.resolveLocale()
                let (l, a) = await (fetchedLocales, fetchedAuto)
                locales = l
                autoLocale = a
                autoLocaleDisplayName = Locale.current.localizedString(forIdentifier: a.identifier) ?? a.identifier
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Subviews

    // Extracted locale to a computed property so `autoDetectedRow` stays a pure
    // @ViewBuilder body without mixing `let` statements before `return`.
    private var autoDetectedDisplayName: String {
        Locale.current.localizedString(forIdentifier: autoLocale.identifier) ?? autoLocale.identifier
    }

    @ViewBuilder
    private var autoDetectedRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                Text(autoDetectedDisplayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if currentLocale.identifier == autoLocale.identifier {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 1.0))
                    .fontWeight(.semibold)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            UISelectionFeedbackGenerator().selectionChanged()
            onSelect(autoLocale.identifier)
            dismiss()
        }
    }

    @ViewBuilder
    private func localeRow(_ locale: Locale) -> some View {
        let displayName = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        let nativeName = locale.localizedString(forIdentifier: locale.identifier) ?? ""
        let isSelected = locale.identifier == currentLocale.identifier

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white)
                if !nativeName.isEmpty && nativeName != displayName {
                    Text(nativeName)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color(red: 0.2, green: 0.6, blue: 1.0))
                    .fontWeight(.semibold)
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.35))
            .padding(.top, 20)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.04, green: 0.04, blue: 0.06))
    }

    // MARK: - Grouping

    private func groupedLocales(from locales: [Locale]) -> [(String, [Locale])] {
        let southAsian  = Set(["en-IN", "hi", "ta", "te", "kn", "ml", "mr", "gu", "pa", "bn", "ur", "or"])
        let eastAsian   = Set(["zh", "ja", "ko"])
        let european    = Set(["en-US", "en-GB", "fr", "de", "es", "it", "pt", "nl", "pl", "sv", "da", "fi", "nb", "ru"])
        let midEastern  = Set(["ar", "he", "tr"])
        let seAsian     = Set(["th", "vi", "id", "ms"])

        var groups: [(String, [Locale])] = [
            ("South Asian",    []),
            ("East Asian",     []),
            ("European",       []),
            ("Middle Eastern", []),
            ("Southeast Asian",[]),
            ("Other",          [])
        ]

        for locale in locales {
            let id   = locale.identifier
            let lang = locale.language.languageCode?.identifier ?? ""

            if southAsian.contains(id) || southAsian.contains(lang) {
                groups[0].1.append(locale)
            } else if eastAsian.contains(lang) {
                groups[1].1.append(locale)
            } else if european.contains(id) || european.contains(lang) {
                groups[2].1.append(locale)
            } else if midEastern.contains(lang) {
                groups[3].1.append(locale)
            } else if seAsian.contains(lang) {
                groups[4].1.append(locale)
            } else {
                groups[5].1.append(locale)
            }
        }

        return groups.filter { !$0.1.isEmpty }
    }
}

#Preview {
    LanguageSelectorView(
        currentLocale: Locale(identifier: "en-IN"),
        onSelect: { _ in }
    )
}
