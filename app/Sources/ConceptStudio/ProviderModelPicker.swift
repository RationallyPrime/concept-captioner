import SwiftUI

struct ProviderModelPicker: View {
    let title: String
    let providerKind: String
    @Binding var model: String
    let choices: [ProviderModelChoice]
    let isRefreshing: Bool
    let refresh: () -> Void
    @State private var enteringCustomModel = false

    private static let otherModel = "__conceptstudio_other_model__"

    private var hasKnownModel: Bool {
        choices.contains { $0.id == model }
    }

    private var selection: Binding<String> {
        Binding(
            get: { enteringCustomModel ? Self.otherModel : model },
            set: { value in
                if value == Self.otherModel {
                    enteringCustomModel = true
                } else {
                    model = value
                    enteringCustomModel = false
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(title, selection: selection) {
                    if model.isEmpty {
                        Text("Choose a model").tag("")
                    } else if !hasKnownModel {
                        Text("\(model) · custom").tag(model)
                    }
                    ForEach(choices) { choice in
                        Text(choice.displayName == choice.id
                            ? choice.id
                            : "\(choice.displayName) · \(choice.id)")
                            .tag(choice.id)
                    }
                    Text("Other model…").tag(Self.otherModel)
                }
                .pickerStyle(.menu)
                .help("Choose a listed model or enter its provider identifier.")

                Button {
                    refresh()
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Refresh")
                    }
                }
                .disabled(isRefreshing)
                .help("Reads the provider’s model list without generating a caption.")
            }

            if enteringCustomModel || (!model.isEmpty && !hasKnownModel) {
                TextField("Model identifier", text: $model)
                    .help("Enter the exact model name from your provider or gateway.")
            }
        }
        .onChange(of: providerKind) { _, _ in enteringCustomModel = false }
    }
}
