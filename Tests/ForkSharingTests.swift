// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shadow Utilities contributors

import Foundation

enum ForkSharingTests {
    static func run(_ suite: TestSuite) {
        let endpoints = [ScreenshotSharingSupport.productionEndpoint,
                         URL(string: "https://test.example")!,
                         URL(string: "http://192.168.12.1")!]
        for endpoint in endpoints {
            for duration in ScreenshotShareDuration.allCases {
                #if SHADOW_UTILITIES
                suite.expect(ScreenshotSharingSupport.uploadURL(endpoint: endpoint, duration: duration) == nil,
                             "fork screenshot sharing cannot create an upload request for any endpoint")
                #else
                suite.expect(ScreenshotSharingSupport.uploadURL(endpoint: endpoint, duration: duration) != nil,
                             "upstream screenshot sharing still creates upload routes")
                #endif
            }
            for duration in RecordingShareDuration.allCases {
                #if SHADOW_UTILITIES
                suite.expect(RecordingSharingSupport.uploadURL(endpoint: endpoint, duration: duration) == nil,
                             "fork recording sharing cannot create an upload request for any endpoint")
                #else
                suite.expect(RecordingSharingSupport.uploadURL(endpoint: endpoint, duration: duration) != nil,
                             "upstream recording sharing still creates upload routes")
                #endif
            }
        }
    }
}
