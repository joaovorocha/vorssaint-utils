// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct TMobileGatewayCredentialFields: View {
    @ObservedObject var form: TMobileGatewayCredentialForm

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Username") {
                TextField("Username", text: $form.username).textFieldStyle(.roundedBorder).labelsHidden()
            }
            LabeledContent("Gateway admin password") {
                SecureField("Gateway admin password", text: $form.password).textFieldStyle(.roundedBorder).labelsHidden()
            }
            Toggle("Remember on this Mac", isOn: Binding(get: { form.remember }, set: { form.setRemember($0) }))
                .help("Save after a successful sign-in. Turning this off forgets the saved password for this gateway and username.")
            HStack {
                Button("Use saved password") { form.useSavedPassword() }
                Button("Forget saved password") { form.forget() }
            }.disabled(!form.scopeIsValid)
            Text("Remembered passwords stay in Keychain for this gateway address and username. Sign-in is always manual.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
