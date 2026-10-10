// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import MapKit
import SwiftUI

/// Renders the production FCC controls against an isolated temporary store.
/// No saved credentials, preferences, gateway readings or network are accessed.
@main @MainActor enum RenderFCCCoverage {
    static func main() throws {
        guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
            print("Usage: RenderFCCCoverage.sh OUTPUT_DIRECTORY [PUBLIC_FCC_ZIP]"); return
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-fcc-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = TMobileCoverageReferenceStore(folder: temporary.appendingPathComponent("reference"))
        let region = MKCoordinateRegion(center: .init(latitude: 38.58, longitude: -121.49),
                                        span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02))
        for width: CGFloat in [480, 900] {
            for dark in [false, true] { try render(store: store, region: region, width: width, dark: dark, name: "empty", output: output) }
        }
        if CommandLine.arguments.count == 3 {
            let package = try TMobileFCCArchiveSupport.extractGeoPackage(
                from: URL(fileURLWithPath: CommandLine.arguments[2]), to: temporary)
            let inspection = try TMobileFCCGeoPackageSupport.inspect(url: package)
            guard let category = inspection.categories.first(where: {
                $0.selection.technology == 500 && $0.selection.minimumDownloadMbps == 35 && $0.selection.minimumUploadMbps == 3
            }) else { throw RenderFailure.invalidFixture }
            let first = category.selection
            let selection = TMobileFCCGeoPackageSupport.Selection(layerName: first.layerName, providerID: 130403,
                technology: 500, minimumDownloadMbps: 35, minimumUploadMbps: 3, environment: 2)
            let result = try TMobileFCCGeoPackageSupport.extract(url: package,
                bounds: .init(west: -121.50, south: 38.57, east: -121.48, north: 38.59), selection: selection)
            let source = TMobileFCCReferenceSource(origin: .localFile, availabilityAsOf: "2025-12-31",
                stateFIPS: nil, technology: 500, minimumDownloadMbps: 35, minimumUploadMbps: 3, environment: 2, fileID: nil)
            guard store.importLayer(data: result.geoJSON, publishedDate: source.availabilityAsOf, source: source),
                  TMobileCoverageReferenceStore(folder: temporary.appendingPathComponent("reference")).layer == store.layer
            else { throw RenderFailure.invalidFixture }
            print("PASS actual public ZIP → native extraction → regional GeoPackage → reference persistence: \(result.metadata.polygonCount) polygons, \(result.metadata.coordinateCount) coordinates")
            for width: CGFloat in [480, 900] {
                for dark in [false, true] { try render(store: store, region: region, width: width, dark: dark, name: "loaded", output: output) }
            }
        }
        print("PASS production FCC controls rendered without account or app-state access")
    }

    private static func render(store: TMobileCoverageReferenceStore, region: MKCoordinateRegion,
                               width: CGFloat, dark: Bool, name: String, output: URL) throws {
        let content = TMobileFCCCoverageView(region: region, references: store)
            .padding(20).frame(width: width).background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
        // ImageRenderer substitutes unsupported markers for AppKit text fields
        // and links. Cache the actual native host so every control is visible.
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 1_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let height = host.fittingSize.height
        guard height.isFinite, height > 0 else { throw RenderFailure.invalidRender }
        window.setContentSize(NSSize(width: width, height: height))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { throw RenderFailure.invalidRender }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RenderFailure.invalidRender }
        try png.write(to: output.appendingPathComponent("fcc-\(name)-\(Int(width))-\(dark ? "dark" : "light").png"), options: .atomic)
        window.orderOut(nil)
    }
    private enum RenderFailure: Error { case invalidFixture, invalidRender }
}
