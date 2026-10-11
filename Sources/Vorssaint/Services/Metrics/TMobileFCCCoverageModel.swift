// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation
import MapKit

/// One workspace owns the flow across tabs. Opening it only probes the exact
/// saved credential without UI; remote requests require the Load action.
@MainActor final class TMobileFCCCoverageModel: ObservableObject {
    struct Request: Sendable {
        let stateFIPS: String
        let technology: FCCCoverageTechnology
        let speedTier: FCCCoverageSpeedTier
        let environment: Int
        let bounds: TMobileFCCGeoPackageSupport.Bounds?
    }
    enum Phase: String { case checking = "Checking latest FCC coverage…", downloading = "Preparing the state download…", importing = "Loading coverage for this map area…" }
    @Published var stateFIPS = FCCCoverageState.california.fips
    @Published var technology = FCCCoverageTechnology.nr
    @Published var speedTier = FCCCoverageSpeedTier.thirtyFiveThree
    @Published var environment = 2
    @Published var datasetDate = ""
    @Published private(set) var catalogue: FCCCoverageCatalogue?
    @Published private(set) var phase: Phase?
    @Published private(set) var message: String?
    @Published private(set) var needsAccess = false
    @Published private(set) var loadedDate: String?
    @Published private(set) var reusedDownload = false
    let credentials: TMobileFCCCredentialForm
    let references: TMobileCoverageReferenceStore
    private let client: FCCCoverageClient
    private let cache: TMobileFCCDownloadCache
    private var task: Task<Void, Never>?

    init(references: TMobileCoverageReferenceStore? = nil,
         credentials: TMobileFCCCredentialForm? = nil,
         client: FCCCoverageClient = FCCCoverageClient(),
         cache: TMobileFCCDownloadCache = TMobileFCCDownloadCache()) {
        let references = references ?? .shared
        self.references = references
        self.credentials = credentials ?? TMobileFCCCredentialForm()
        self.client = client; self.cache = cache
        if let source = references.layer?.source {
            stateFIPS = source.stateFIPS ?? FCCCoverageState.california.fips
            technology = FCCCoverageTechnology(rawValue: String(source.technology)) ?? .nr
            speedTier = source.minimumDownloadMbps == 7 ? .sevenOne : .thirtyFiveThree
            environment = source.environment == 1 ? 1 : 2
        }
        datasetDate = references.layer?.publishedDate ?? ""
    }
    var busy: Bool { phase != nil }
    var stateName: String { FCCCoverageState.all.first { $0.fips == stateFIPS }?.name ?? "Selected state" }
    var summary: String { "\(stateName) · \(technology.title) · \(technology == .nr ? speedTier.title : "5/1 Mbps") · \(environment == 1 ? "In vehicle" : "Outdoors")" }
    func prepare() { credentials.prepareSavedAccess() }
    func cancel() { task?.cancel() }
    func close() { task?.cancel(); credentials.clear() }
    func dismissMessage() { message = nil }

    static func bounds(for region: MKCoordinateRegion?) -> TMobileFCCGeoPackageSupport.Bounds? {
        guard let region else { return nil }
        let west = region.center.longitude - region.span.longitudeDelta / 2
        let east = region.center.longitude + region.span.longitudeDelta / 2
        let south = region.center.latitude - region.span.latitudeDelta / 2
        let north = region.center.latitude + region.span.latitudeDelta / 2
        guard [west, east, south, north].allSatisfy(\.isFinite), west >= -180, east <= 180,
              south >= -90, north <= 90, west < east, south < north else { return nil }
        return .init(west: west, south: south, east: east, north: north)
    }
    private func snapshot(region: MKCoordinateRegion?) -> Request {
        .init(stateFIPS: stateFIPS, technology: technology, speedTier: speedTier,
              environment: environment, bounds: Self.bounds(for: region))
    }
    func loadCoverage(region: MKCoordinateRegion?, onLoaded: @escaping @MainActor () -> Void = {}) {
        guard !busy else { return }
        prepare()
        guard Self.bounds(for: region) != nil else { message = ImportFailure.chooseArea.errorDescription; return }
        guard credentials.isValid else {
            needsAccess = true
            message = credentials.savedAccessState == .locked ? credentials.message : ImportFailure.access.errorDescription
            return
        }
        if credentials.needsSave {
            credentials.save()
            guard !credentials.needsSave else { needsAccess = true; message = ImportFailure.saveAccess.errorDescription; return }
        }
        needsAccess = false
        let request = snapshot(region: region)
        let access = FCCCoverageCredentials(username: credentials.username, token: credentials.token)
        begin {
            self.phase = .checking
            let catalogue = try await self.client.checkLatestMobileCoverage(stateFIPS: request.stateFIPS, credentials: access)
            try Task.checkCancellation()
            self.catalogue = catalogue; self.datasetDate = catalogue.asOfDate
            guard let file = catalogue.files.first(where: {
                $0.geometry == .raw && $0.technology == request.technology
                    && (request.technology == .lte || $0.speedTier == request.speedTier)
            }) else { throw ImportFailure.noFile }
            self.phase = .downloading
            let download = try await self.cache.obtain(file: file, credentials: access, client: self.client)
            try Task.checkCancellation()
            self.reusedDownload = download.reused
            self.phase = .importing
            do {
                try await self.load(download.url, asOfDate: file.asOfDate, apiFile: file, request: request)
            } catch {
                if Self.shouldDiscardDownload(after: error) {
                    try? await self.cache.invalidate(file: file)
                }
                throw error
            }
            self.message = "Coverage loaded · FCC data as of \(file.asOfDate)."
            onLoaded()
        }
    }
    private static func shouldDiscardDownload(after error: Error) -> Bool {
        if let error = error as? TMobileFCCArchiveSupport.ArchiveError {
            switch error {
            case .invalidArchive, .checksumMismatch, .unsafeFile: return true
            case .unsupportedArchive, .sizeLimit, .destinationUnavailable: return false
            }
        }
        if let error = error as? TMobileFCCGeoPackageSupport.Failure {
            switch error {
            case .cannotRead, .malformedGeometry, .invalidModeledSignal, .invalidSpatialIndex: return true
            default: return false
            }
        }
        return false
    }
    func importLocal(_ url: URL, region: MKCoordinateRegion?, onLoaded: @escaping @MainActor () -> Void = {}) {
        guard !busy else { return }
        let request = snapshot(region: region), date = datasetDate
        begin {
            self.phase = .importing
            try await self.load(url, asOfDate: date, apiFile: nil, request: request)
            self.message = "Local coverage loaded · data as of \(date)."
            onLoaded()
        }
    }
    private func begin(_ operation: @escaping @MainActor () async throws -> Void) {
        phase = .checking; message = nil
        task = Task {
            do { try await operation() }
            catch {
                if Task.isCancelled || error is CancellationError || (error as? FCCCoverageFailure) == .cancelled {
                    message = "Loading cancelled. Your existing coverage is retained."
                } else {
                    if let failure = error as? FCCCoverageFailure, failure == .authentication || failure == .forbidden {
                        credentials.rejectAccess(); needsAccess = true
                    }
                    message = (error as? LocalizedError)?.errorDescription ?? "Unable to load coverage. Try again."
                }
            }
            phase = nil; task = nil
        }
    }
    private func load(_ url: URL, asOfDate: String, apiFile: FCCCoverageDataFile?, request: Request) async throws {
        guard TMobileCoverageReferenceSupport.validDate(asOfDate) else { throw ImportFailure.chooseArea }
        let mapBounds = request.bounds
        let radio = apiFile?.technology ?? request.technology
        let tier = apiFile?.speedTier ?? (radio == .nr ? request.speedTier : nil)
        let environment = request.environment
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
        loadedDate = asOfDate
    }
    enum ImportFailure: LocalizedError {
        case chooseArea, fileType, category, save, access, saveAccess, noFile
        var errorDescription: String? {
            switch self {
            case .access: return "Enter your FCC email and token once to load coverage. They will be saved in Keychain on this Mac."
            case .saveAccess: return "FCC access could not be saved. Unlock Keychain and try again."
            case .noFile: return "FCC has no matching T-Mobile file for these coverage options. Choose another technology or speed."
            case .chooseArea: return "Choose a local area on the map, then load its coverage."
            case .fileType: return "Choose an FCC raw coverage ZIP, GeoPackage or Polygon/MultiPolygon GeoJSON file."
            case .category: return "This file has no unique matching T-Mobile category. Select its technology, speed and environment, then try again."
            case .save: return "Unable to save this coverage reference. The previous overlay is retained."
            }
        }
    }
}
