// FMIntentSchema.swift
// STT — FoundationModelNLU (evaluation sample; see docs/FM_SAMPLE_PLAN.md)
//
// The @Generable intent vocabulary for guided generation. Constrained decoding
// means the model structurally cannot emit a case outside this enum — no
// hallucinated labels, no malformed output, ever.
//
// PARITY CONTRACT: `label` values must exactly match the `labels` array in
// Resources/intent_classifier_weights.json (the app's classifier source of
// truth — 60 labels: 59 in-scope + "Default Fallback Intent"). Enforced by
// FMSchemaParityTests; if an intent is added to the production classifier,
// that test fails until this enum follows.
//
// Case names are deliberately descriptive English ("increaseVolume", not
// "cmdVolumeIncrease"): with guided generation the *case names* are what the
// model reasons over, so they double as classification hints. The `label`
// mapping recovers the exact production label string.

import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
enum FMIntent: String, CaseIterable, Sendable {
    // Activity / health queries
    case activityAerobics, activityCalories, activityCycle, activityExercise
    case activityRun, activityStand, activitySteps, activityWalk
    case healthSummary
    // Device commands
    case batteryLevel, findMyPhone
    case listenToMessages, sendMessage, sendMessageConfirmNo, sendMessageConfirmYes
    case changeHearingMemory
    case startStreaming, stopStreaming
    case startTranscription, startTranslation
    case volumeDown, volumeUp, volumeMute, volumeUnmute
    // Reminders
    case addReminder, completeReminder
    // Help topics (product questions, not commands)
    case helpAccessories, helpAppSettings, helpBattery, helpChangingMemories
    case helpCleanCare, helpCustomize, helpDemoMode, helpDeviceSettings
    case helpEdgeMode, helpFallAlert, helpFindMyHearingAids, helpHealth
    case helpHearShare, helpHearingCareAnywhereConnect, helpHeartRate
    case helpHeartRateRecovery, helpHome, helpInsertDevice, helpIntelliVoice
    case helpMaskMode, helpMemoryOptions, helpPairing, helpReminder
    case helpRemoteProgramming, helpSelfCheck, helpThriveScore, helpTinnitus
    case helpTranscribe, helpTranslate, helpVoiceAssistant, helpVolume
    case helpWhatsNew, helpWiCROS
    // Anything not covered above
    case outOfScope

    /// The production intent label — must byte-match intent_classifier_weights.json.
    var label: String {
        switch self {
        case .activityAerobics:      return "Cmd.ActivityAerobics"
        case .activityCalories:      return "Cmd.ActivityCalories"
        case .activityCycle:         return "Cmd.ActivityCycle"
        case .activityExercise:      return "Cmd.ActivityExercise"
        case .activityRun:           return "Cmd.ActivityRun"
        case .activityStand:         return "Cmd.ActivityStand"
        case .activitySteps:         return "Cmd.ActivityStep"
        case .activityWalk:          return "Cmd.ActivityWalk"
        case .healthSummary:         return "Cmd.Health"
        case .batteryLevel:          return "Cmd.BatteryLevel"
        case .findMyPhone:           return "Cmd.FindMyPhone"
        case .listenToMessages:      return "Cmd.ListenMessage"
        case .sendMessage:           return "Cmd.SendMessage"
        case .sendMessageConfirmNo:  return "Cmd.SendMessage - no"
        case .sendMessageConfirmYes: return "Cmd.SendMessage - yes"
        case .changeHearingMemory:   return "Cmd.MemoryChange"
        case .startStreaming:        return "Cmd.StreamingStart"
        case .stopStreaming:         return "Cmd.StreamingStop"
        case .startTranscription:    return "Cmd.TranscribeStart"
        case .startTranslation:      return "Cmd.TranslationStart"
        case .volumeDown:            return "Cmd.VolumeDecrease"
        case .volumeUp:              return "Cmd.VolumeIncrease"
        case .volumeMute:            return "Cmd.VolumeMute"
        case .volumeUnmute:          return "Cmd.VolumeUnmute"
        case .addReminder:           return "reminders.add"
        case .completeReminder:      return "reminders.complete"
        case .helpAccessories:       return "Help_Accessories"
        case .helpAppSettings:       return "Help_AppSettings"
        case .helpBattery:           return "Help_Battery"
        case .helpChangingMemories:  return "Help_ChangingMemories"
        case .helpCleanCare:         return "Help_CleanCare"
        case .helpCustomize:         return "Help_Customize"
        case .helpDemoMode:          return "Help_DemoMode"
        case .helpDeviceSettings:    return "Help_DeviceSettings"
        case .helpEdgeMode:          return "Help_EdgeMode"
        case .helpFallAlert:         return "Help_FallAlert"
        case .helpFindMyHearingAids: return "Help_FindMyHearingAids"
        case .helpHealth:            return "Help_Health"
        case .helpHearShare:         return "Help_HearShare"
        case .helpHearingCareAnywhereConnect: return "Help_HearingCareAnywhereConnect"
        case .helpHeartRate:         return "Help_HeartRate"
        case .helpHeartRateRecovery: return "Help_HeartRateRecovery"
        case .helpHome:              return "Help_Home"
        case .helpInsertDevice:      return "Help_InsertDevice"
        case .helpIntelliVoice:      return "Help_IntelliVoice"
        case .helpMaskMode:          return "Help_MaskMode"
        case .helpMemoryOptions:     return "Help_MemoryOptions"
        case .helpPairing:           return "Help_Pairing"
        case .helpReminder:          return "Help_Reminder"
        case .helpRemoteProgramming: return "Help_RemoteProgramming"
        case .helpSelfCheck:         return "Help_SelfCheck"
        case .helpThriveScore:       return "Help_ThriveScore"
        case .helpTinnitus:          return "Help_Tinnitus"
        case .helpTranscribe:        return "Help_Transcribe"
        case .helpTranslate:         return "Help_Translate"
        case .helpVoiceAssistant:    return "Help_VoiceAssistant"
        case .helpVolume:            return "Help_Volume"
        case .helpWhatsNew:          return "Help_WhatsNew"
        case .helpWiCROS:            return "Help_WiCROS"
        case .outOfScope:            return "Default Fallback Intent"
        }
    }

    /// One-line description used by FMPromptBuilder in the instruction catalog.
    /// Kept terse — the full catalog must fit the session context with room to spare.
    var catalogDescription: String {
        switch self {
        case .activityAerobics:      return "aerobics activity stats"
        case .activityCalories:      return "calories burned"
        case .activityCycle:         return "cycling activity stats"
        case .activityExercise:      return "exercise minutes / general workout stats"
        case .activityRun:           return "running activity stats"
        case .activityStand:         return "stand hours"
        case .activitySteps:         return "step count"
        case .activityWalk:          return "walking activity stats"
        case .healthSummary:         return "overall health/body data summary"
        case .batteryLevel:          return "hearing-aid battery level"
        case .findMyPhone:           return "locate the user's phone"
        case .listenToMessages:      return "play/read incoming messages aloud"
        case .sendMessage:           return "compose and send a message"
        case .sendMessageConfirmNo:  return "user declining to send the drafted message"
        case .sendMessageConfirmYes: return "user confirming to send the drafted message"
        case .changeHearingMemory:   return "switch hearing-aid memory/program/preset"
        case .startStreaming:        return "start audio streaming to hearing aids"
        case .stopStreaming:         return "stop audio streaming"
        case .startTranscription:    return "open live transcription"
        case .startTranslation:      return "open live translation"
        case .volumeDown:            return "lower hearing-aid volume (incl. 'too loud')"
        case .volumeUp:              return "raise hearing-aid volume (incl. 'too quiet', 'can't hear')"
        case .volumeMute:            return "mute hearing aids"
        case .volumeUnmute:          return "unmute hearing aids"
        case .addReminder:           return "create a reminder"
        case .completeReminder:      return "mark a reminder done"
        case .helpAccessories:       return "how accessories work"
        case .helpAppSettings:       return "how app settings work"
        case .helpBattery:           return "battery questions (life, charging) — question, not a level check"
        case .helpChangingMemories:  return "how to change memories/programs — question, not the command"
        case .helpCleanCare:         return "cleaning and care instructions"
        case .helpCustomize:         return "how to customize sound"
        case .helpDemoMode:          return "what demo mode is"
        case .helpDeviceSettings:    return "how device settings work"
        case .helpEdgeMode:          return "what Edge Mode is"
        case .helpFallAlert:         return "how fall alert works"
        case .helpFindMyHearingAids: return "how to locate lost hearing aids"
        case .helpHealth:            return "how health tracking works — question, not a stats request"
        case .helpHearShare:         return "what HearShare is"
        case .helpHearingCareAnywhereConnect: return "remote hearing care connection help"
        case .helpHeartRate:         return "how heart-rate tracking works"
        case .helpHeartRateRecovery: return "what heart-rate recovery means"
        case .helpHome:              return "home screen help"
        case .helpInsertDevice:      return "how to insert/wear the hearing aids"
        case .helpIntelliVoice:      return "what IntelliVoice is"
        case .helpMaskMode:          return "what mask mode is"
        case .helpMemoryOptions:     return "what memory/program options exist"
        case .helpPairing:           return "how to pair hearing aids"
        case .helpReminder:          return "how reminders work — question, not creating one"
        case .helpRemoteProgramming: return "how remote programming works"
        case .helpSelfCheck:         return "how self-check diagnostics work"
        case .helpThriveScore:       return "what the Thrive score is"
        case .helpTinnitus:          return "tinnitus relief features"
        case .helpTranscribe:        return "how transcription works — question, not opening it"
        case .helpTranslate:         return "how translation works — question, not opening it"
        case .helpVoiceAssistant:    return "how the voice assistant works"
        case .helpVolume:            return "how volume control works — question, not a change"
        case .helpWhatsNew:          return "what's new in the app"
        case .helpWiCROS:            return "what Wi-CROS is"
        case .outOfScope:            return "ANYTHING else: weather, general knowledge, chit-chat, other apps"
        }
    }

    /// Reverse lookup: production label → enum case. Used by the benchmark to
    /// map holdout expectations onto the enum.
    static func from(label: String) -> FMIntent? {
        Self.allCases.first { $0.label == label }
    }
}
#endif
