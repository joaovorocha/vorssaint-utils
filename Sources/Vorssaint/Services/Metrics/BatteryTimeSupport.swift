// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum BatteryTimeSupport {
    static func remainingSeconds(timeToEmptyMinutes: Int?,
                                 externalConnected: Bool,
                                 isCharging: Bool) -> TimeInterval? {
        guard !externalConnected,
              !isCharging,
              let minutes = timeToEmptyMinutes,
              (1..<(7 * 24 * 60)).contains(minutes) else { return nil }
        return TimeInterval(minutes * 60)
    }

    static func formatted(seconds: TimeInterval) -> String? {
        totalMinutes(seconds: seconds).map { "\($0 / 60)h \($0 % 60)m" }
    }

    static func compactFormatted(seconds: TimeInterval) -> String? {
        totalMinutes(seconds: seconds).map { String(format: "%d:%02d", $0 / 60, $0 % 60) }
    }

    private static func totalMinutes(seconds: TimeInterval) -> Int? {
        guard seconds.isFinite, seconds > 0, seconds / 60 < Double(Int.max) else { return nil }
        return max(1, Int(seconds / 60))
    }
}
