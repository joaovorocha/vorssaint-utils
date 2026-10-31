// SPDX-License-Identifier: GPL-3.0-or-later

/// One decision per app process, independent of Coverage window visibility.
/// Changing the saved opt-in during a run affects the next launch only, so a
/// user's Stop cannot be followed by an implicit restart in the same run.
struct TMobileCoverageRecordingStartup {
    private var handledAppLaunch = false

    mutating func shouldStartAfterAppLaunch(enabled: Bool, networkAvailable: Bool) -> Bool {
        guard !handledAppLaunch else { return false }
        handledAppLaunch = true
        return enabled && networkAvailable
    }
}
