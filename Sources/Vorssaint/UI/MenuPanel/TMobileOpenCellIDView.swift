// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Explicit online lookup, separate from local references and gateway sessions.
struct TMobileOpenCellIDView: View {
    @StateObject private var service = TMobileOpenCellIDService()
    @State private var radio = TMobileOpenCellIDRadio.nr
    @State private var mcc = ""
    @State private var mnc = ""
    @State private var tac = ""
    @State private var cellID = ""
    @State private var token = ""
    @State private var confirmed = false
    @State private var requestTask: Task<Void, Never>?

    private var identity: TMobileOpenCellIDIdentity? {
        .init(radio: radio, mcc: mcc, mnc: mnc, tac: tac, cellID: cellID)
    }
    private var busy: Bool { service.phase == .loading }
    private var enteredIdentity: String { "\(radio.rawValue)|\(mcc)|\(mnc)|\(tac)|\(cellID)" }

    var body: some View {
        GroupBox("Optional online cell lookup") {
            VStack(alignment: .leading, spacing: 12) {
                Text("A manual lookup sends the selected network identifiers and your API key to OpenCellID over HTTPS. The provider also receives your network address. Nothing is sent until you choose Look up this cell.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Enter the full LTE ECI or 5G NCI from a trusted source. A gateway CID or a node ID may be only a fragment; this app never expands or guesses it. MCC, MNC and TAC are also entered manually.")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                    GridRow { Text("Radio"); Picker("Radio", selection: $radio) {
                        ForEach(TMobileOpenCellIDRadio.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented) }
                    GridRow { Text("MCC"); TextField("3 decimal digits", text: $mcc) }
                    GridRow { Text("MNC"); TextField("1–3 decimal digits", text: $mnc) }
                    GridRow { Text("TAC"); TextField(radio == .lte ? "0–65,535" : "0–16,777,215", text: $tac) }
                    GridRow { Text(radio == .lte ? "Full ECI" : "Full NCI"); TextField(radio == .lte ? "0–268,435,455" : "0–68,719,476,735", text: $cellID) }
                    GridRow { Text("API key"); SecureField("OpenCellID API key · kept only in memory", text: $token) }
                }.textFieldStyle(.roundedBorder).disabled(busy)
                if let identity {
                    Text("Will send: \(identity.disclosure)").font(.callout).monospacedDigit().textSelection(.enabled)
                } else {
                    Text("Complete all identifier fields using decimal digits without spaces or separators.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("I verified these are the correct full cell identifiers and approve sending them to OpenCellID", isOn: $confirmed)
                    .font(.callout).disabled(busy)
                HStack {
                    Button("Look up this cell") { lookup() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || identity == nil || !confirmed || !TMobileOpenCellIDSupport.validToken(token))
                    Button(busy ? "Cancel lookup" : "Clear lookup") { clear() }
                    if busy { ProgressView().controlSize(.small); Text("Looking up one cell…").font(.callout) }
                }
                if let message = service.message { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true) }
                if let result = service.result { resultView(result) }
                HStack {
                    Link("OpenCellID API guide", destination: TMobileOpenCellIDSupport.documentation)
                    Link("Get an OpenCellID key", destination: TMobileOpenCellIDSupport.provider)
                }.font(.caption)
                Text("No measurements, gateway credentials, Wi-Fi settings or saved tower files are uploaded. Lookups and keys are cleared when this view closes. Results are not saved to local pins or history.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: enteredIdentity) { _, _ in clear(); confirmed = false }
        .onDisappear { clear(); confirmed = false }
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
            Text("OpenCellID coverage comes from community observations. This result does not confirm that the gateway is attached to this tower.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("Cell tower data from")
                Link("OpenCellID", destination: TMobileOpenCellIDSupport.provider)
                Text("·")
                Link("CC BY-SA 4.0", destination: TMobileOpenCellIDSupport.license)
            }.font(.caption)
            Text("Display change: coordinates rounded to up to 4 decimal places.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lookup() {
        guard let identity, confirmed, TMobileOpenCellIDSupport.validToken(token) else { return }
        let enteredToken = token
        token = ""
        requestTask?.cancel()
        requestTask = Task { await service.lookup(identity: identity, token: enteredToken, confirmedFullIdentity: true) }
    }
    private func clear() {
        requestTask?.cancel(); requestTask = nil; token = ""; service.clear()
    }
}
