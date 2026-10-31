// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import MapKit
import SwiftUI

/// Human-requested online references, separate from measurements and gateway sessions.
struct TMobileOpenCellIDView: View {
    var region: MKCoordinateRegion? = nil
    var onAreaResults: (([TMobileOpenCellIDResult]) -> Void)? = nil
    var onSaveResult: ((TMobileOpenCellIDResult) -> Void)? = nil
    @StateObject private var service = TMobileOpenCellIDService()
    @StateObject private var credentials = TMobileOpenCellIDCredentialForm()
    @State private var radio = TMobileOpenCellIDRadio.nr
    @State private var mcc = ""
    @State private var mnc = ""
    @State private var tac = ""
    @State private var cellID = ""
    @State private var confirmed = false
    @State private var requestTask: Task<Void, Never>?

    private var area: TMobileOpenCellIDArea? {
        guard let center = region?.center else { return nil }
        return .init(latitude: center.latitude, longitude: center.longitude)
    }
    private var identity: TMobileOpenCellIDIdentity? {
        .init(radio: radio, mcc: mcc, mnc: mnc, tac: tac, cellID: cellID)
    }
    private var busy: Bool { service.phase == .loading }
    private var enteredIdentity: String { "\(radio.rawValue)|\(mcc)|\(mnc)|\(tac)|\(cellID)" }

    var body: some View {
        GroupBox("Nearby community cell estimates") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste your OpenCellID key, move the map to your area, then find nearby cells. Each search covers a 1.8 km square around the map center and returns up to 50 estimates for the selected radio.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("API key") {
                    SecureField("OpenCellID API key", text: $credentials.token)
                        .textFieldStyle(.roundedBorder).labelsHidden()
                }.disabled(busy)
                ViewThatFits(in: .horizontal) {
                    HStack { keyButtons }
                    VStack(alignment: .leading, spacing: 8) { keyButtons }
                }.disabled(busy)
                if let message = credentials.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 10) {
                    Text("Radio").fixedSize()
                    Picker("Radio", selection: $radio) {
                        Text("LTE").tag(TMobileOpenCellIDRadio.lte)
                        Text("5G (NR)").tag(TMobileOpenCellIDRadio.nr)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 180)
                }.disabled(busy)
                Text("Selecting Find cells sends this map area and your API key to OpenCellID over HTTPS. The provider also receives your network address. Provider quotas apply; searches run only when you select the button.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Find cells near map center") { search() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || area == nil || !credentials.validToken)
                    Button(busy ? "Cancel lookup" : "Clear lookup") { clear() }
                    if busy { ProgressView().controlSize(.small) }
                }
                if area == nil {
                    Text(region == nil ? "Waiting for the map to choose a search area…" : "Move the map away from the poles or date line to choose a supported search area.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = service.message { Text(message).font(.callout) }
                if !service.areaResults.isEmpty { areaResultList }
                if let result = service.result { resultView(result) }
                DisclosureGroup("Advanced: look up a full cell identifier") {
                    manualLookup.padding(.top, 8)
                }
                HStack {
                    Link("Get an OpenCellID key", destination: TMobileOpenCellIDSupport.provider)
                    Link("Area search guide", destination: TMobileOpenCellIDAreaSupport.documentation)
                }.font(.caption)
                Text("Community positions are estimates, not confirmed physical towers or your gateway’s serving tower. No measurements or gateway credentials are uploaded. Results stay temporary unless you save an estimate; the key stays in memory unless you explicitly save it in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: enteredIdentity) { _, _ in clear(); confirmed = false }
        .onChange(of: service.areaResults) { _, results in onAreaResults?(results) }
        .onDisappear {
            requestTask?.cancel(); requestTask = nil
            credentials.clearVolatile(); confirmed = false
        }
    }

    @ViewBuilder private var keyButtons: some View {
        Button("Save API key on this Mac") { credentials.saveKey() }.disabled(!credentials.validToken)
        Button("Use saved key") { credentials.useSavedKey() }
        Button("Forget saved key") { clear(); credentials.forgetKey() }
    }

    private var manualLookup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter the full LTE ECI or 5G NCI from a trusted source. A gateway CID or node ID may be only a fragment; it is never expanded or guessed here.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow { Text("MCC"); TextField("3 decimal digits", text: $mcc) }
                GridRow { Text("MNC"); TextField("1–3 decimal digits", text: $mnc) }
                GridRow { Text("TAC"); TextField(radio == .lte ? "0–65,535" : "0–16,777,215", text: $tac) }
                GridRow { Text(radio == .lte ? "Full ECI" : "Full NCI"); TextField(radio == .lte ? "0–268,435,455" : "0–68,719,476,735", text: $cellID) }
            }.textFieldStyle(.roundedBorder).disabled(busy)
            if let identity {
                Text("Will send: \(identity.disclosure)").font(.callout).monospacedDigit().textSelection(.enabled)
            } else {
                Text("Use decimal digits without spaces or separators.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("I verified the full identifiers and approve sending them to OpenCellID", isOn: $confirmed)
                .font(.callout).disabled(busy)
            Button("Look up this cell") { lookup() }
                .disabled(busy || identity == nil || !confirmed || !credentials.validToken)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var areaResultList: some View {
        VStack(alignment: .leading, spacing: 8) {
            attribution
            DisclosureGroup("Returned cell estimates (\(service.areaResults.count))") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(service.areaResults.enumerated()), id: \.offset) { _, result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.identity.disclosure).font(.caption).monospacedDigit().textSelection(.enabled)
                            HStack {
                                Text("\(result.latitude.formatted(.number.precision(.fractionLength(3)))), \(result.longitude.formatted(.number.precision(.fractionLength(3))))")
                                    .font(.caption).monospacedDigit().textSelection(.enabled)
                                if let onSaveResult { Button("Save estimate") { onSaveResult(result) }.controlSize(.small) }
                            }
                        }
                    }
                }.padding(.top, 8)
            }
            Text("Provider coordinates are rounded. Results are filtered to the last searched area and duplicate cell identities are removed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var attribution: some View {
        HStack(spacing: 5) {
            Text("Cell data:")
            Link("OpenCellID", destination: TMobileOpenCellIDSupport.provider)
            Text("·")
            Link("CC BY-SA 4.0", destination: TMobileOpenCellIDSupport.license)
        }.font(.caption)
    }

    private func resultView(_ result: TMobileOpenCellIDResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            Text("Community cell position · location unverified").font(.headline)
            Text(result.identity.disclosure).font(.callout).monospacedDigit()
            Text("Latitude \(result.latitude.formatted(.number.precision(.fractionLength(0...4)))), longitude \(result.longitude.formatted(.number.precision(.fractionLength(0...4))))")
                .font(.callout).monospacedDigit().textSelection(.enabled)
            if let range = result.rangeMeters {
                Text("Provider range: \(range.formatted()) m. This is not a verified accuracy radius.").font(.caption)
            }
            if let samples = result.samples { Text("Provider samples: \(samples)").font(.caption) }
            attribution
            Text("Display change: coordinates rounded to up to 4 decimal places.").font(.caption).foregroundStyle(.secondary)
            if let onSaveResult {
                Button("Save estimate to reference map") { onSaveResult(result) }.buttonStyle(.bordered)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func search() {
        guard let area, credentials.validToken else { return }
        let enteredToken = credentials.token
        requestTask?.cancel()
        let enteredRadio = radio
        requestTask = Task {
            await service.search(area: area, radio: enteredRadio, token: enteredToken, approvedAreaSharing: true)
        }
    }
    private func lookup() {
        guard let identity, confirmed, credentials.validToken else { return }
        onAreaResults?([])
        let enteredToken = credentials.token
        requestTask?.cancel()
        requestTask = Task { await service.lookup(identity: identity, token: enteredToken, confirmedFullIdentity: true) }
    }
    private func clear() {
        requestTask?.cancel(); requestTask = nil; service.clear(); onAreaResults?([])
    }
}
