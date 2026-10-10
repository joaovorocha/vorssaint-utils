// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// Nationwide catalogue access is explicit. Map bounds are used only on this Mac.
@MainActor struct TMobileFCCCoverageView: View {
    let region: MKCoordinateRegion?
    @ObservedObject var references: TMobileCoverageReferenceStore = .shared
    @StateObject private var credentials = TMobileFCCCredentialForm()
    @State private var client = FCCCoverageClient()
    @State private var stateFIPS = FCCCoverageState.california.fips
    @State private var technology = FCCCoverageTechnology.nr
    @State private var speedTier = FCCCoverageSpeedTier.thirtyFiveThree
    @State private var environment = 2
    @State private var catalogue: FCCCoverageCatalogue?
    @State private var datasetDate = ""
    @State private var showAPIAccess = true
    @State private var importFile = false
    @State private var downloadedURL: URL?
    @State private var task: Task<Void, Never>?
    @State private var phase: String?
    @State private var message: String?

    private var busy: Bool { phase != nil }
    private var selectedFile: FCCCoverageDataFile? {
        catalogue?.files.first {
            $0.geometry == .raw && $0.technology == technology
                && (technology == .lte || $0.speedTier == speedTier)
        }
    }
    private var bounds: TMobileFCCGeoPackageSupport.Bounds? {
        guard let region else { return nil }
        let halfLatitude = region.span.latitudeDelta / 2
        let halfLongitude = region.span.longitudeDelta / 2
        let west = region.center.longitude - halfLongitude, east = region.center.longitude + halfLongitude
        let south = region.center.latitude - halfLatitude, north = region.center.latitude + halfLatitude
        guard [west, east, south, north].allSatisfy(\.isFinite), west >= -180, east <= 180,
              south >= -90, north <= 90, west < east, south < north else { return nil }
        return .init(west: west, south: south, east: east, north: north)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("FCC modeled coverage", systemImage: "map").font(.headline)
            Text("Compare T-Mobile’s published coverage with your recorded readings. FCC models describe outdoor or in-vehicle availability; they do not identify towers, radio bands or indoor coverage.")
                .font(.callout).foregroundStyle(.secondary)
            selectors.disabled(busy)
            DisclosureGroup("FCC API access", isExpanded: $showAPIAccess) { credentialControls.padding(.top, 8) }
            if bounds == nil {
                Text("Zoom the map to a local area before loading coverage. Areas crossing the date line need a closer view.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { catalogueActions }
                VStack(alignment: .leading, spacing: 10) { catalogueActions }
            }
            if let catalogue {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(catalogue.state.name) · data as of \(catalogue.asOfDate)").font(.headline)
                    Text("Checked \(catalogue.checkedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    if let source = references.layer?.source, source.stateFIPS == catalogue.state.fips {
                        Text(source.availabilityAsOf < catalogue.asOfDate ? "A newer FCC dataset is available for this state." : (source.availabilityAsOf == catalogue.asOfDate ? "The imported availability date matches the latest date returned by FCC." : "The imported date is newer than FCC’s latest date. Verify the date entered for this file."))
                            .font(.callout)
                    }
                    if selectedFile == nil {
                        Text("FCC returned no matching T-Mobile raw coverage file for this state and category. Try another category or use the official download page.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Download the state file, then load model polygons intersecting the selected map area. Zoom in first; detailed areas may need a closer view.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let phase {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(phase).font(.callout)
                    Button("Cancel") { task?.cancel() }
                }
            }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            if let url = downloadedURL {
                Button("Load saved ZIP for map area") { begin { try await load(url, asOfDate: datasetDate, apiFile: nil) } }
                    .disabled(busy || !TMobileCoverageReferenceSupport.validDate(datasetDate) || bounds == nil)
                Text("The ZIP remains at your chosen destination. Reloads use local-file provenance because saved files can change. Verify the entered date if you replace the file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            localImportControls
            if let layer = references.layer {
                VStack(alignment: .leading, spacing: 4) {
                    Text(layer.title).font(.callout.bold())
                    Text("\(layer.polygons.count) polygons · \(layer.provenance)").font(.caption).foregroundStyle(.secondary)
                    Button("Remove reference") { references.removeLayer() }.disabled(busy)
                }.textSelection(.enabled)
            }
            Text("Checks send your FCC email and token to FCC over HTTPS; downloads request the selected state’s file. Your precise map area, recordings and gateway credentials stay on this Mac. Each person uses their own FCC token; checks run only when requested.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.zip, .json, UTType(filenameExtension: "gpkg") ?? .data, UTType(filenameExtension: "geojson") ?? .json]) { result in
            if case .success(let url) = result { begin { try await load(url, asOfDate: datasetDate, apiFile: nil) } }
        }
        .onChange(of: stateFIPS) { _, _ in catalogue = nil; message = nil }
        .onDisappear { task?.cancel(); credentials.clear() }
    }

    private var selectors: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { stateAndRadio }
                VStack(alignment: .leading, spacing: 10) { stateAndRadio }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { tierAndEnvironment }
                VStack(alignment: .leading, spacing: 10) { tierAndEnvironment }
            }
        }
    }

    @ViewBuilder private var tierAndEnvironment: some View {
        if technology == .nr {
            Picker("Modeled speed", selection: $speedTier) {
                ForEach(FCCCoverageSpeedTier.allCases) { Text($0.title).tag($0) }
            }.frame(maxWidth: 250)
        }
        Picker("Environment", selection: $environment) {
            Text("Outdoor stationary").tag(2)
            Text("In vehicle").tag(1)
        }.frame(maxWidth: 300)
    }

    @ViewBuilder private var stateAndRadio: some View {
        Picker("State or territory", selection: $stateFIPS) {
            ForEach(FCCCoverageState.all) { Text($0.name).tag($0.fips) }
        }.frame(maxWidth: 330)
        Picker("Technology", selection: $technology) {
            ForEach(FCCCoverageTechnology.allCases) { Text($0.title).tag($0) }
        }.frame(maxWidth: 210)
    }

    private var credentialControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in on the FCC website, open Manage API Access, and generate a token. Enter the account email and token here.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("FCC email")
                    TextField("", text: $credentials.username, prompt: Text(verbatim: "name@example.com"))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("FCC email")
                }
                GridRow {
                    Text("API token")
                    SecureField("Paste FCC token", text: $credentials.token)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("FCC API token")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { credentialActions }
                VStack(alignment: .leading, spacing: 8) { credentialActions }
            }
            if let message = credentials.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Link("Manage FCC API access", destination: FCCCoverageSupport.tokenPage)
                Link("FCC API instructions", destination: FCCCoverageSupport.specification)
            }.font(.caption)
        }.disabled(busy)
    }

    @ViewBuilder private var credentialActions: some View {
        Button("Save access on this Mac") { credentials.save() }.disabled(!credentials.isValid)
        Button("Use saved access") { credentials.useSaved() }
        Button("Forget saved access") { credentials.forget() }
    }

    @ViewBuilder private var catalogueActions: some View {
        Button("Check for updates") {
            let access = FCCCoverageCredentials(username: credentials.username, token: credentials.token)
            let state = stateFIPS
            begin {
                phase = "Checking FCC datasets…"
                let result = try await client.checkLatestMobileCoverage(stateFIPS: state, credentials: access)
                try Task.checkCancellation()
                catalogue = result
                datasetDate = result.asOfDate
            }
        }.disabled(busy || !credentials.isValid)
        Button("Download & load map area…") { download() }
            .disabled(busy || selectedFile == nil || !credentials.isValid || bounds == nil)
        Link("Open FCC downloads", destination: FCCCoverageSupport.downloadPage)
    }

    private var localImportControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Already downloaded a file?").font(.callout.bold())
            Text("Choose Raw Coverage → GeoPackage on the FCC download page. Enter the Availability Data As Of date, zoom the map to your area, then import the ZIP or GeoPackage. A new reference replaces the previous overlay.")
                .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { localActions }
                VStack(alignment: .leading, spacing: 10) { localActions }
            }
            Text("Local files are checked for compatible contents; their FCC origin and manually entered date remain declared by you. Polygon/MultiPolygon GeoJSON is imported in full, within the geometry limit.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var localActions: some View {
        HStack {
            Text("Data as of").fixedSize()
            TextField("YYYY-MM-DD", text: $datasetDate).textFieldStyle(.roundedBorder).frame(width: 140).disabled(busy)
        }
        Button("Import local coverage file…") { importFile = true }
            .disabled(busy || !TMobileCoverageReferenceSupport.validDate(datasetDate))
    }

    private func begin(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        phase = "Reading FCC coverage…"; message = nil
        task = Task {
            do { try await operation() }
            catch is CancellationError { message = "FCC operation cancelled. The existing reference is retained." }
            catch { message = (error as? LocalizedError)?.errorDescription ?? "Unable to load FCC data. Try the official download page." }
            phase = nil; task = nil
        }
    }

    private func download() {
        guard let file = selectedFile else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = file.fileName.hasSuffix(".zip") ? file.fileName : file.fileName + ".zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let access = FCCCoverageCredentials(username: credentials.username, token: credentials.token)
        begin {
            phase = "Downloading FCC state coverage…"
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            let url = try await client.downloadGeoPackage(file: file, to: destination, credentials: access)
            downloadedURL = url
            phase = "Loading model polygons for this map area…"
            try await load(url, asOfDate: file.asOfDate, apiFile: file)
        }
    }

    private func load(_ url: URL, asOfDate: String, apiFile: FCCCoverageDataFile?) async throws {
        guard TMobileCoverageReferenceSupport.validDate(asOfDate) else { throw ImportFailure.chooseArea }
        let mapBounds = bounds
        let radio = apiFile?.technology ?? technology
        let tier = apiFile?.speedTier ?? (radio == .nr ? speedTier : nil)
        let environment = environment
        let worker = Task.detached(priority: .userInitiated) { () throws -> (Data, TMobileFCCGeoPackageSupport.Selection?) in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try Task.checkCancellation()
            if ["json", "geojson"].contains(url.pathExtension.lowercased()) {
                return (try TMobileCoverageReferenceSupport.readLocalFile(at: url), nil)
            }
            guard let bounds = mapBounds else { throw ImportFailure.chooseArea }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-fcc-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let package: URL
            if url.pathExtension.lowercased() == "zip" {
                package = try TMobileFCCArchiveSupport.extractGeoPackage(from: url, to: temporary)
            } else if url.pathExtension.lowercased() == "gpkg" { package = url }
            else { throw ImportFailure.fileType }
            let inspection = try TMobileFCCGeoPackageSupport.inspect(url: package)
            let categories = inspection.categories.filter { category in
                let value = category.selection
                return value.providerID == 130403 && value.technology == Int(radio.rawValue)
                    && (tier == nil || (value.minimumDownloadMbps == (tier == .thirtyFiveThree ? 35 : 7)
                        && value.minimumUploadMbps == (tier == .thirtyFiveThree ? 3 : 1)))
                    && (environment == 2 || value.environment == environment)
            }
            guard let first = categories.first?.selection,
                  Set(categories.map { $0.selection.layerName }).count == 1,
                  categories.allSatisfy({ $0.selection.minimumDownloadMbps == first.minimumDownloadMbps
                      && $0.selection.minimumUploadMbps == first.minimumUploadMbps }) else { throw ImportFailure.category }
            let selection = TMobileFCCGeoPackageSupport.Selection(layerName: first.layerName, providerID: first.providerID,
                technology: first.technology, minimumDownloadMbps: first.minimumDownloadMbps,
                minimumUploadMbps: first.minimumUploadMbps, environment: environment)
            let result = try TMobileFCCGeoPackageSupport.extract(url: package, bounds: bounds, selection: selection)
            return (result.geoJSON, selection)
        }
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        let source = result.1.map { selection in
            TMobileFCCReferenceSource(origin: apiFile == nil ? .localFile : .officialAPI,
                availabilityAsOf: asOfDate, stateFIPS: apiFile?.stateFIPS, technology: selection.technology,
                minimumDownloadMbps: selection.minimumDownloadMbps, minimumUploadMbps: selection.minimumUploadMbps,
                environment: selection.environment, fileID: apiFile?.id)
        }
        guard references.importLayer(data: result.0, publishedDate: asOfDate, source: source) else {
            throw ImportFailure.save
        }
        message = result.1 == nil
            ? "The complete GeoJSON reference is loaded on this Mac. Your recorded readings are retained."
            : "FCC reference loaded on this Mac. It shows complete model polygons intersecting the selected map area; your recorded readings are retained."
    }

    private enum ImportFailure: LocalizedError {
        case chooseArea, fileType, category, save
        var errorDescription: String? {
            switch self {
            case .chooseArea: return "Enter the dataset date and zoom the map to the local area you want to compare."
            case .fileType: return "Choose an FCC raw coverage ZIP, GeoPackage or Polygon/MultiPolygon GeoJSON file."
            case .category: return "This file has no unique matching T-Mobile category. Select its technology, speed and environment, then try again."
            case .save: return "Unable to save this coverage reference. The previous overlay is retained."
            }
        }
    }
}
