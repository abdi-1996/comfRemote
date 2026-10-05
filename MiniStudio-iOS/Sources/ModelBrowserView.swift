import SwiftUI

struct LoaderTarget: Identifiable, Codable, Hashable {
    let id: String
    let graphIndex: Int
    let nodeId: String
    let nodeTitle: String
    let nodeType: String
    let widget: String
    let category: String
    var value: String
    var options: [String]
}

private struct LoaderTargetDetailView: View {
    @ObservedObject var browser: StudioBrowser
    let targetID: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var target: LoaderTarget? {
        browser.loaderTargets.first(where: { $0.id == targetID })
    }

    private var filteredOptions: [String] {
        guard let target else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return target.options }
        return target.options.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if let target {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(target.nodeTitle).font(.headline)
                        Text(target.nodeType).font(.caption).foregroundStyle(.secondary)
                        Text("Current: \(target.value)").font(.caption).textSelection(.enabled)
                    }
                    Button {
                        browser.browseOnPC(target)
                    } label: {
                        Label("Browse on PC", systemImage: "folder")
                    }
                    .disabled(browser.modelPickerBusy)
                } footer: {
                    Text("Browse on PC opens the Windows file picker on the computer running ComfyUI. Files outside the selected ComfyUI model folder are imported automatically.")
                }

                Section("ComfyUI models") {
                    if filteredOptions.isEmpty {
                        Text("No matching models").foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredOptions, id: \.self) { option in
                            Button {
                                browser.applyLoader(target, value: option)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(option).foregroundStyle(.primary).lineLimit(2)
                                    Spacer()
                                    if option == target.value {
                                        Image(systemName: "checkmark").foregroundStyle(.mint)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Text("This loader is no longer available. Refresh the workflow.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(target?.nodeTitle ?? "Model")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search models")
    }
}

struct ModelBrowserView: View {
    @ObservedObject var browser: StudioBrowser
    @Environment(\.dismiss) private var dismiss

    private func icon(for category: String) -> String {
        switch category {
        case "loras": return "slider.horizontal.3"
        case "text_encoders": return "text.bubble"
        case "vae": return "film.stack"
        case "checkpoints": return "shippingbox"
        default: return "cpu"
        }
    }

    private func title(for category: String) -> String {
        switch category {
        case "loras": return "LoRA"
        case "text_encoders": return "Text Encoder"
        case "vae": return "VAE"
        case "checkpoints": return "Checkpoint"
        default: return "Diffusion Model"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if browser.loaderTargets.isEmpty && browser.modelPickerBusy {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Reading model loaders from the current workflow…")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else if browser.loaderTargets.isEmpty {
                    ContentUnavailableView(
                        "No model loaders found",
                        systemImage: "shippingbox",
                        description: Text("Open the MiniMax H3 workflow in ComfyUI, then tap Refresh.")
                    )
                } else {
                    List(browser.loaderTargets) { target in
                        NavigationLink {
                            LoaderTargetDetailView(browser: browser, targetID: target.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: target.category))
                                    .frame(width: 28)
                                    .foregroundStyle(.mint)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title(for: target.category)).font(.caption).foregroundStyle(.secondary)
                                    Text(target.nodeTitle).font(.headline).lineLimit(1)
                                    Text(target.value).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Models & LoRA")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        browser.refreshLoaderTargets()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(browser.modelPickerBusy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !browser.modelPickerMessage.isEmpty {
                    Text(browser.modelPickerMessage)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.thinMaterial)
                }
            }
        }
        .onAppear { browser.refreshLoaderTargets() }
    }
}
