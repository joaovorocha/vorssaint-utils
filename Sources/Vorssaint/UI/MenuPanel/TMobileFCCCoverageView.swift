// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// One primary task, with account/category/file details disclosed as needed.
@MainActor struct TMobileFCCCoverageView: View {
    let region: MKCoordinateRegion?
    var onChooseArea: () -> Void = {}
    var onLoaded: () -> Void = {}
    @ObservedObject var model: TMobileFCCCoverageModel
    @ObservedObject private var credentials: TMobileFCCCredentialForm
    @ObservedObject private var references: TMobileCoverageReferenceStore
    @State private var showAccount = false
    @State private var showOptions = false
    @State private var showImport = false
    @State private var importFile = false
    @State private var replaceAccess = false

    init(region: MKCoordinateRegion?, references: TMobileCoverageReferenceStore? = nil,
         model: TMobileFCCCoverageModel? = nil,
         onChooseArea: @escaping () -> Void = {}, onLoaded: @escaping () -> Void = {}) {
        let flow = model ?? TMobileFCCCoverageModel(references: references)
        self.region = region; self.model = flow; self.credentials = flow.credentials
        self.references = flow.references; self.onChooseArea = onChooseArea; self.onLoaded = onLoaded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("FCC modeled coverage", systemImage: "map").font(.headline)
                Text("Compare T-Mobile’s published coverage with your readings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(model.summary).font(.callout.weight(.semibold))
                Label(region == nil ? "Choose an area on the map" : "Area: current map view", systemImage: "viewfinder")
                    .font(.callout).foregroundStyle(.secondary)
                if let phase = model.phase {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(phase.rawValue).font(.callout)
                        Spacer(minLength: 8)
                        Button("Cancel") { model.cancel() }
                    }
                    Text("You can view the map while this finishes.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { loadActions }
                        VStack(alignment: .leading, spacing: 10) { loadActions }
                    }
                    Text("Finds the latest FCC data and reuses a verified download when available. No file picker needed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.message {
                    Text(message).font(.callout).textSelection(.enabled)
                }
                if let layer = references.layer {
                    Label("Loaded · data as of \(layer.publishedDate)", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            DisclosureGroup(isExpanded: $showAccount) {
                accountControls.padding(.top, 10)
            } label: {
                HStack(spacing: 8) {
                    Text("FCC access")
                    Text(accessSummary).font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Coverage options", isExpanded: $showOptions) {
                selectors.padding(.top, 10)
            }
            DisclosureGroup("Import a local file", isExpanded: $showImport) {
                localImportControls.padding(.top, 10)
            }
            Text("FCC models describe outdoor and in-vehicle service. They do not identify towers, radio bands or indoor coverage.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Your FCC access goes only to FCC over HTTPS. Map coordinates and recordings stay on this Mac. Downloads start when you select Load coverage.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.zip, .json, UTType(filenameExtension: "gpkg") ?? .data, UTType(filenameExtension: "geojson") ?? .json]) { result in
            if case .success(let url) = result { model.importLocal(url, region: region, onLoaded: onLoaded) }
        }
        .onAppear {
            model.prepare()
            if model.needsAccess || !credentials.isValid { showAccount = true }
        }
        .onChange(of: model.needsAccess) { _, needed in if needed { showAccount = true } }
    }

    @ViewBuilder private var loadActions: some View {
        if TMobileFCCCoverageModel.bounds(for: region) == nil {
            Button("Choose area on map", action: onChooseArea).buttonStyle(.borderedProminent)
        } else {
            Button("Load coverage for this area") {
                model.loadCoverage(region: region, onLoaded: onLoaded)
                if model.needsAccess { showAccount = true }
            }.buttonStyle(.borderedProminent)
            Button("Choose another area", action: onChooseArea)
        }
        if references.layer != nil { Button("Show on map", action: onLoaded) }
    }

    private var accessSummary: String {
        if credentials.isValid { return credentials.needsSave ? "Ready to save" : "Saved in Keychain" }
        switch credentials.savedAccessState {
        case .locked: return "Unlock Keychain to continue"
        case .invalid: return "Update token"
        case .unchecked: return "Checking Keychain…"
        case .missing, .available: return "Token needed once"
        }
    }
    private var accountControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if credentials.savedAccessState == .locked {
                Button("Unlock saved access") { credentials.useSaved() }
                Text("Keychain may ask you to allow this app to use its saved FCC access.")
                    .font(.caption).foregroundStyle(.secondary)
                if !replaceAccess {
                    Button("Use another token…") { replaceAccess = true }
                }
            }
            if credentials.savedAccessState != .locked || replaceAccess {
                Text("Enter your FCC account email and API token once. Loading coverage saves them in this Mac’s Keychain.")
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
                    HStack(spacing: 10) { accountActions }
                    VStack(alignment: .leading, spacing: 10) { accountActions }
                }
                Link("Get or renew an FCC API token", destination: FCCCoverageSupport.tokenPage).font(.caption)
            }
            if let message = credentials.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.disabled(model.busy)
    }
    @ViewBuilder private var accountActions: some View {
        if credentials.needsSave { Button("Save access") { credentials.save() }.disabled(!credentials.isValid) }
        if credentials.savedAccessState != .locked {
            Button("Check Keychain again") { credentials.useSaved() }
        }
        if credentials.savedAccessState != .missing {
            Button("Forget saved access") { credentials.forget() }
        }
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
            Text("Applies to the next load. Your current map stays available until the new area is ready.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(model.busy)
    }
    @ViewBuilder private var stateAndRadio: some View {
        Picker("State or territory", selection: $model.stateFIPS) {
            ForEach(FCCCoverageState.all) { Text($0.name).tag($0.fips) }
        }.frame(maxWidth: 330)
        Picker("Technology", selection: $model.technology) {
            ForEach(FCCCoverageTechnology.allCases) { Text($0.title).tag($0) }
        }.frame(maxWidth: 210)
    }
    @ViewBuilder private var tierAndEnvironment: some View {
        if model.technology == .nr {
            Picker("Modeled speed", selection: $model.speedTier) {
                ForEach(FCCCoverageSpeedTier.allCases) { Text($0.title).tag($0) }
            }.frame(maxWidth: 250)
        }
        Picker("Environment", selection: $model.environment) {
            Text("Outdoors").tag(2); Text("In vehicle").tag(1)
        }.frame(maxWidth: 300)
    }
    private var localImportControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use an FCC Raw Coverage ZIP or GeoPackage you already have. Enter its Availability Data As Of date.")
                .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { importActions }
                VStack(alignment: .leading, spacing: 10) { importActions }
            }
            if let layer = references.layer {
                Text(layer.title).font(.caption).textSelection(.enabled)
                Button("Remove coverage reference") { references.removeLayer() }.disabled(model.busy)
            }
            Link("Open FCC downloads", destination: FCCCoverageSupport.downloadPage).font(.caption)
            Text("Local-file origin and date are declared by you. A successful import replaces the existing coverage overlay.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var importActions: some View {
        HStack {
            Text("Data as of").fixedSize()
            TextField("YYYY-MM-DD", text: $model.datasetDate).textFieldStyle(.roundedBorder).frame(width: 140)
        }
        Button("Choose coverage file…") { importFile = true }
            .disabled(model.busy || !TMobileCoverageReferenceSupport.validDate(model.datasetDate))
    }
}
