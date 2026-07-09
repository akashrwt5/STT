// MemoryProbe.swift
// STT
//
// Diagnostic-only. Walks the process's VM regions via Mach APIs to classify
// memory as dirty (anonymous, charged against the jetsam budget) vs. clean /
// file-backed (evictable by iOS under memory pressure).
//
// Used to characterize the cost of SpeechTranscriber model loading via
// AssetInventory.reserve(locale:). DEBUG-only — empty/no-op in Release.

#if DEBUG

import Foundation
import Darwin
import os.log

enum MemoryProbe {

    // MARK: - Public Types

    struct RegionBucket {
        var residentBytes: UInt64 = 0
        var dirtyBytes: UInt64 = 0
        var swappedBytes: UInt64 = 0
        var regionCount: Int = 0
        var fileBackedRegions: Int = 0
        var privateRegions: Int = 0
    }

    struct Snapshot {
        let label: String
        let timestamp: Date
        // task_vm_info process-wide totals
        let physFootprint: UInt64   // exactly what jetsam measures
        let residentSize: UInt64
        let anonDirty: UInt64       // task_vm_info.internal
        let fileBacked: UInt64      // task_vm_info.external
        let compressed: UInt64
        // per-tag breakdown of the region walk
        let buckets: [Int: RegionBucket]
        let regionCount: Int
    }

    // MARK: - Capture

    /// Capture a process memory snapshot. Walks all VM regions; takes a few ms
    /// on real hardware (small enough to call inline around the call site you
    /// want to measure).
    static func snapshot(label: String) -> Snapshot {
        let totals = readTaskVMInfo()
        let (buckets, count) = walkRegions()
        let s = Snapshot(
            label: label,
            timestamp: Date(),
            physFootprint: totals.phys,
            residentSize: totals.resident,
            anonDirty: totals.anon,
            fileBacked: totals.external,
            compressed: totals.compressed,
            buckets: buckets,
            regionCount: count
        )
        // print() so output is always visible in Xcode's console regardless of
        // unified-logging filtering. logger.notice should also fire.
        print("[MemoryProbe] snapshot '\(label)': phys=\(fmt(s.physFootprint)) resident=\(fmt(s.residentSize)) anon=\(fmt(s.anonDirty)) ext=\(fmt(s.fileBacked))")
        logger.notice("[MemoryProbe] snapshot '\(label, privacy: .public)' captured.")
        return s
    }

    // MARK: - Reporting

    private static let logger = Logger(subsystem: "com.voiceintentkit", category: "MemoryProbe")

    /// Log a single snapshot (totals only — useful as a baseline).
    static func log(_ s: Snapshot) {
        logger.notice("━━━ MemoryProbe '\(s.label, privacy: .public)' ━━━")
        logger.notice("phys_footprint: \(fmt(s.physFootprint), privacy: .public)   [jetsam budget]")
        logger.notice("resident_size:  \(fmt(s.residentSize), privacy: .public)")
        logger.notice("anon dirty:     \(fmt(s.anonDirty), privacy: .public)   [task_vm_info.internal]")
        logger.notice("file-backed:    \(fmt(s.fileBacked), privacy: .public)   [task_vm_info.external]")
        logger.notice("compressed:     \(fmt(s.compressed), privacy: .public)")
        logger.notice("regions:        \(s.regionCount)")
    }

    /// Log a before/after diff with a verdict on dirty vs. clean growth.
    static func logDiff(before: Snapshot, after: Snapshot) {
        // print() mirror so the diff is visible even when os_log is filtered.
        print("[MemoryProbe] ━━━ '\(before.label)' → '\(after.label)' ━━━")
        print("[MemoryProbe]   phys_footprint Δ: \(signedFmt(after.physFootprint, before.physFootprint))   [jetsam]")
        print("[MemoryProbe]   resident Δ:       \(signedFmt(after.residentSize, before.residentSize))")
        print("[MemoryProbe]   anon dirty Δ:     \(signedFmt(after.anonDirty, before.anonDirty))")
        print("[MemoryProbe]   file-backed Δ:    \(signedFmt(after.fileBacked, before.fileBacked))")

        logger.notice("━━━ MemoryProbe '\(before.label, privacy: .public)' → '\(after.label, privacy: .public)' ━━━")
        logger.notice("phys_footprint: \(fmt(before.physFootprint), privacy: .public) → \(fmt(after.physFootprint), privacy: .public)   (\(signedFmt(after.physFootprint, before.physFootprint), privacy: .public))   [jetsam budget]")
        logger.notice("resident_size:  \(fmt(before.residentSize), privacy: .public) → \(fmt(after.residentSize), privacy: .public)   (\(signedFmt(after.residentSize, before.residentSize), privacy: .public))")
        logger.notice("anon dirty:     \(fmt(before.anonDirty), privacy: .public) → \(fmt(after.anonDirty), privacy: .public)   (\(signedFmt(after.anonDirty, before.anonDirty), privacy: .public))   [real cost]")
        logger.notice("file-backed:    \(fmt(before.fileBacked), privacy: .public) → \(fmt(after.fileBacked), privacy: .public)   (\(signedFmt(after.fileBacked, before.fileBacked), privacy: .public))   [evictable]")
        logger.notice("compressed:     \(fmt(before.compressed), privacy: .public) → \(fmt(after.compressed), privacy: .public)   (\(signedFmt(after.compressed, before.compressed), privacy: .public))")
        logger.notice("regions:        \(before.regionCount) → \(after.regionCount)")

        // Per-tag deltas (>= 256 KB resident change)
        var deltas: [TagDelta] = []
        let allTags = Set(before.buckets.keys).union(after.buckets.keys)
        for tag in allTags {
            let b = before.buckets[tag] ?? RegionBucket()
            let a = after.buckets[tag] ?? RegionBucket()
            let dR = Int64(a.residentBytes) - Int64(b.residentBytes)
            let dD = Int64(a.dirtyBytes) - Int64(b.dirtyBytes)
            // file-backed bytes for a region ≈ resident - dirty - swapped
            let extA = Int64(a.residentBytes) - Int64(a.dirtyBytes) - Int64(a.swappedBytes)
            let extB = Int64(b.residentBytes) - Int64(b.dirtyBytes) - Int64(b.swappedBytes)
            let dE = extA - extB
            if abs(dR) >= 256 * 1024 || abs(dD) >= 256 * 1024 {
                deltas.append(TagDelta(tag: tag, resident: dR, dirty: dD, fileBacked: dE,
                                      newRegions: a.regionCount - b.regionCount))
            }
        }
        deltas.sort { abs($0.resident) > abs($1.resident) }

        logger.notice("Top per-tag deltas (≥ 256 KB):")
        for d in deltas.prefix(15) {
            let name = tagName(d.tag)
            let dirtyPct: Int
            if d.resident > 0 {
                dirtyPct = max(0, min(100, Int(100 * max(0, d.dirty) / max(d.resident, 1))))
            } else {
                dirtyPct = 0
            }
            logger.notice("  [\(d.tag, privacy: .public)/\(name, privacy: .public)]  resident=\(signed(d.resident), privacy: .public)  dirty=\(signed(d.dirty), privacy: .public)  file-backed=\(signed(d.fileBacked), privacy: .public)  (\(dirtyPct)% of growth is dirty)  newRegions=\(d.newRegions)")
        }

        // Verdict
        let footDelta = Int64(after.physFootprint) - Int64(before.physFootprint)
        let resDelta = Int64(after.residentSize) - Int64(before.residentSize)
        let extDelta = Int64(after.fileBacked) - Int64(before.fileBacked)
        let intDelta = Int64(after.anonDirty) - Int64(before.anonDirty)
        let cleanPct: Int
        if resDelta > 0 {
            cleanPct = max(0, min(100, Int(100 * max(0, extDelta) / resDelta)))
        } else {
            cleanPct = 0
        }
        logger.notice("━━━ VERDICT ━━━")
        logger.notice("phys_footprint Δ: \(signed(footDelta), privacy: .public)   ← what jetsam sees")
        logger.notice("resident Δ:       \(signed(resDelta), privacy: .public)")
        logger.notice("anon dirty Δ:     \(signed(intDelta), privacy: .public)   ← actual budget cost")
        logger.notice("file-backed Δ:    \(signed(extDelta), privacy: .public)   ← evictable (\(cleanPct)% of resident growth)")
        if resDelta > 0 {
            if cleanPct >= 75 {
                logger.notice("→ mostly CLEAN / mmap. Evictable under pressure. Low real cost.")
            } else if cleanPct >= 40 {
                logger.notice("→ MIXED. Roughly \(cleanPct)% clean / \(100 - cleanPct)% dirty.")
            } else {
                logger.notice("→ mostly DIRTY. On the jetsam budget. Real cost ≈ resident growth.")
            }
        }
    }

    // MARK: - Mach Plumbing

    private struct VMTotals {
        var phys: UInt64 = 0
        var resident: UInt64 = 0
        var anon: UInt64 = 0
        var external: UInt64 = 0
        var compressed: UInt64 = 0
    }

    private static func readTaskVMInfo() -> VMTotals {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return VMTotals() }
        return VMTotals(
            phys: info.phys_footprint,
            resident: UInt64(info.resident_size),
            anon: info.internal,
            external: info.external,
            compressed: info.compressed
        )
    }

    private static func walkRegions() -> (buckets: [Int: RegionBucket], count: Int) {
        var buckets: [Int: RegionBucket] = [:]
        var regionCount = 0
        // `vm_kernel_page_size` is a shared kernel var that Swift 6 flags as
        // non-concurrency-safe. `getpagesize()` returns the same value via POSIX.
        let pageSize = UInt64(getpagesize())

        var address: vm_address_t = 0
        var depth: natural_t = 0

        while true {
            var size: vm_size_t = 0
            var info = vm_region_submap_info_data_64_t()
            var localCount = mach_msg_type_number_t(
                MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<integer_t>.size
            )

            let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(localCount)) { rebound in
                    vm_region_recurse_64(mach_task_self_, &address, &size, &depth, rebound, &localCount)
                }
            }
            if kr != KERN_SUCCESS { break }

            if info.is_submap != 0 {
                depth += 1
                continue
            }

            regionCount += 1
            let tag = Int(info.user_tag)
            var bucket = buckets[tag, default: RegionBucket()]
            bucket.residentBytes += UInt64(info.pages_resident) * pageSize
            bucket.dirtyBytes    += UInt64(info.pages_dirtied) * pageSize
            bucket.swappedBytes  += UInt64(info.pages_swapped_out) * pageSize
            bucket.regionCount   += 1

            // share_mode: SM_COW=1, SM_PRIVATE=2, SM_EMPTY=3, SM_SHARED=4,
            // SM_TRUESHARED=5, SM_PRIVATE_ALIASED=6, SM_SHARED_ALIASED=7,
            // SM_LARGE_PAGE=8. (See <mach/vm_region.h>.)
            switch Int32(info.share_mode) {
            case SM_COW, SM_SHARED, SM_TRUESHARED, SM_SHARED_ALIASED:
                bucket.fileBackedRegions += 1
            case SM_PRIVATE, SM_PRIVATE_ALIASED:
                bucket.privateRegions += 1
            default:
                break
            }
            buckets[tag] = bucket

            address += size
        }
        return (buckets, regionCount)
    }

    // MARK: - Formatting

    private struct TagDelta {
        let tag: Int
        let resident: Int64
        let dirty: Int64
        let fileBacked: Int64
        let newRegions: Int
    }

    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useMB, .useKB]
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static func fmt(_ v: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(v))
    }

    private static func signed(_ v: Int64) -> String {
        let sign = v >= 0 ? "+" : "-"
        return sign + byteFormatter.string(fromByteCount: Int64(abs(v)))
    }

    private static func signedFmt(_ a: UInt64, _ b: UInt64) -> String {
        signed(Int64(a) - Int64(b))
    }

    /// Human name for the common VM_MEMORY_* user tags. Unknown tags fall back
    /// to "tag_N" so the raw number is still visible.
    private static func tagName(_ tag: Int) -> String {
        switch tag {
        case 0:  return "UNTAGGED"
        case 1:  return "MALLOC"
        case 2:  return "MALLOC_SMALL"
        case 3:  return "MALLOC_LARGE"
        case 4:  return "MALLOC_HUGE"
        case 7:  return "MALLOC_TINY"
        case 8:  return "MALLOC_LARGE_REUSABLE"
        case 9:  return "MALLOC_LARGE_REUSED"
        case 11: return "MALLOC_NANO"
        case 12: return "MALLOC_MEDIUM"
        case 20: return "MACH_MSG"
        case 21: return "IOKIT"
        case 30: return "STACK"
        case 31: return "GUARD"
        case 33: return "DYLIB"
        case 34: return "OBJC_DISPATCHERS"
        case 40: return "APPKIT"
        case 41: return "FOUNDATION"
        case 42: return "COREGRAPHICS"
        case 43: return "CORESERVICES"
        case 45: return "COREDATA"
        case 51: return "CORE_ANIMATION"
        case 52: return "CGIMAGE"
        case 54: return "CG_DATA"
        case 60: return "DYLD"
        case 61: return "DYLD_MALLOC"
        case 62: return "SQLITE"
        case 66: return "GLSL"
        case 67: return "OPENCL"
        case 68: return "COREIMAGE"
        case 70: return "IMAGEIO"
        case 73: return "OS_ALLOC_ONCE"
        case 74: return "LIBDISPATCH"
        case 75: return "ACCELERATE"
        case 82: return "SWIFT_RUNTIME"
        case 83: return "SWIFT_METADATA"
        case 87: return "SKYWALK"
        case 88: return "IOSURFACE"
        case 89: return "LIBNETWORK"
        case 90: return "AUDIO"
        default:
            if (240...255).contains(tag) { return "APP_SPECIFIC(\(tag))" }
            return "tag_\(tag)"
        }
    }
}

#endif
