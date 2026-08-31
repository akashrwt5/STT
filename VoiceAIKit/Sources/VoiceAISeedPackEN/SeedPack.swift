// SeedPack.swift
// VoiceAISeedPackEN
//
// The English pack, shipped as an SPM resource, so an app gets it by linking a
// library instead of dragging a folder into Xcode.
//
// WHY THIS IS A SEPARATE TARGET FROM `VoiceAIKit`
//
// `VoiceAIKit` ships zero data — that is the point of the whole refactor,
// and the acceptance test is that `Bundle.module` appears nowhere in it. Putting
// the pack in that target would undo it: any code there could then read a pack
// out of its own bundle, which is `LanguagePackRegistry` again in new clothes.
// The reason that failed is not aesthetic — a pack baked into a binary can never
// be one published after the app shipped, and most of 23 languages will be.
//
// As a separate target the boundary is a fact rather than a rule:
// `VoiceAIKit` is a different module with a different bundle and literally
// cannot see this pack.
//
// It also makes the seed OPTIONAL. Xcode asks which of a package's libraries to
// link; an app that downloads every language ticks only `VoiceAIKit` and
// carries 0 MB instead of 8.8 MB. With one target every app pays, including the
// Russian-only user shipping an English pack they will never use.
//
// Note this is a BUILD-time copy, not a runtime one: SwiftPM emits a resource
// bundle and Xcode embeds it in the `.app`. Those bytes are in the IPA and count
// against the App Store download — which is exactly why the seed is one language
// and the rest are fetched.
//
// `.copy` and not `.process`: `.copy` preserves the directory tree verbatim.
// The pack format's structure IS its data — `capabilities/<id>/responses/<lang>.json`
// carries the capability and the language in the PATH, `integrity/manifest.sha256`
// lists every file by path, and there are two different `IntentClassifier.mlpackage`
// under `models/intent/en/`. Anything that flattens breaks all three.

import Foundation

public enum VoiceAISeedPackEN {

    /// The seed pack's directory inside the host app's bundle, or nil if the
    /// resource did not make it in.
    ///
    /// Found by SCANNING rather than `Bundle.module.url(forResource:withExtension:)`.
    /// That API splits a name into stem and extension, and this pack is called
    /// `pack-en-v1.0.30` — three dots. It returns a silent nil on names like
    /// that, which is indistinguishable from "the resource is missing", and two
    /// causes behind one symptom is how a whole afternoon goes.
    ///
    /// Scanning also keeps the version out of the source: shipping
    /// `pack-en-v1.0.31` is a file swap, not a code edit.
    public static var url: URL? {
        guard let packsRoot = Bundle.module.url(forResource: "packs", withExtension: nil),
              let names = try? FileManager.default.contentsOfDirectory(atPath: packsRoot.path),
              let newest = names.filter({ $0.hasPrefix("pack-en-v") }).sorted().last
        else { return nil }
        return packsRoot.appendingPathComponent(newest, isDirectory: true)
    }

    /// The language this seed serves.
    public static let language = "en"
}
