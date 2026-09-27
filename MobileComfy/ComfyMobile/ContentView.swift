import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: WorkflowStore
    @AppStorage("comfyServerURL") private var serverURL = "http://100.x.x.x:8188"

    @State private var showingSettings = false
    @State private var busy = false
    @State private var generationProgress = 0.0
    @State private var statusText = ""
    @State private var showingAlert = false

    var body: some View {
        ZStack(alignment: .top) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 18) {
                        workflowHeader

                        if let item = store.selected {
                            materialsSection(item)
                            promptSection(item)
                            seedSection(item)
                            customParametersSection(item)
                            generateButton
                        } else {
                            emptyState
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView(serverURL: $serverURL)
                        .environmentObject(store)
                }
                .alert("Comfy Mobile", isPresented: $showingAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(statusText)
                }
            }

            if busy {
                ProgressView(value: generationProgress, total: 1)
                    .progressViewStyle(.linear)
                    .frame(height: 2)
                    .zIndex(10)
            }
        }
    }

    @ViewBuilder
    private var workflowHeader: some View {
        if let item = store.selected {
            HStack(spacing: 12) {
                Text(item.name)
                    .font(.title2.bold())
                    .lineLimit(2)

                Spacer()

                Button {
                    openComfyInBrowser()
                } label: {
                    Image(systemName: "pencil")
                        .font(.title3.weight(.semibold))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Открыть workflow в ComfyUI")
            }
        } else {
            HStack {
                Text("Workflow не выбран")
                    .font(.title2.bold())
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
    }

    @ViewBuilder
    private func materialsSection(_ item: WorkflowItem) -> some View {
        let materials = store.materials(for: item)

        if !materials.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Материалы")
                    .font(.headline)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(materials) { material in
                            MaterialTile(
                                material: material,
                                serverURL: serverURL,
                                onStatus: showStatus
                            )
                            .environmentObject(store)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func promptSection(_ item: WorkflowItem) -> some View {
        if let prompt = store.primaryPromptParameter(for: item) {
            CleanParameterEditor(
                title: "Prompt",
                parameter: prompt,
                multiline: true
            )
            .environmentObject(store)
        }
    }

    @ViewBuilder
    private func seedSection(_ item: WorkflowItem) -> some View {
        if let seed = store.primarySeedParameter(for: item) {
            SeedEditor(parameter: seed)
                .environmentObject(store)
        }
    }

    @ViewBuilder
    private func customParametersSection(_ item: WorkflowItem) -> some View {
        let custom = store.exposedParameters(for: item)

        if !custom.isEmpty {
            VStack(spacing: 12) {
                ForEach(custom) { parameter in
                    CleanParameterEditor(
                        title: parameter.key.replacingOccurrences(of: "_", with: " "),
                        parameter: parameter,
                        multiline: false
                    )
                    .environmentObject(store)
                }
            }
        }
    }

    private var generateButton: some View {
        Button {
            Task {
                await generate()
            }
        } label: {
            HStack {
                Spacer()
                if busy {
                    ProgressView()
                        .padding(.trailing, 8)
                }
                Text("GENERATE")
                    .font(.headline.bold())
                Spacer()
            }
            .frame(height: 52)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy || store.selected?.apiPromptJSON == nil)
        .padding(.top, 4)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Нет workflow",
            systemImage: "point.3.connected.trianglepath.dotted",
            description: Text("Открой настройки и импортируй JSON")
        )
        .padding(.top, 80)
    }

    private func openComfyInBrowser() {
        guard let url = ComfyClient.normalizedBaseURL(serverURL) else {
            showStatus("Неверный адрес ComfyUI. Исправь его в настройках.")
            return
        }

        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                Task { @MainActor in
                    showStatus("Не удалось открыть Safari")
                }
            }
        }
    }

    private func showStatus(_ text: String) {
        statusText = text
        showingAlert = true
    }

    @MainActor
    private func generate() async {
        guard let prompt = store.apiPromptObject() else {
            showStatus("У workflow нет API prompt")
            return
        }

        busy = true
        generationProgress = 0.03

        do {
            let promptID = try await ComfyClient.queue(base: serverURL, prompt: prompt)
            generationProgress = 0.08

            var finished = false
            var checks = 0

            while !finished && checks < 3600 {
                try await Task.sleep(for: .seconds(1))
                checks += 1

                finished = try await ComfyClient.generationFinished(
                    base: serverURL,
                    promptID: promptID
                )

                if finished {
                    generationProgress = 1
                    try? await Task.sleep(for: .milliseconds(450))
                    statusText = "Готово"
                } else {
                    let remaining = 0.92 - generationProgress
                    generationProgress = min(0.92, generationProgress + max(0.003, remaining * 0.035))
                }
            }

            if !finished {
                statusText = "Генерация ещё выполняется"
            }
        } catch {
            showStatus(error.localizedDescription)
        }

        busy = false
        generationProgress = 0
    }
}

private struct CleanParameterEditor: View {
    @EnvironmentObject private var store: WorkflowStore

    let title: String
    let parameter: WorkflowParameter
    let multiline: Bool

    @State private var value: String

    init(title: String, parameter: WorkflowParameter, multiline: Bool) {
        self.title = title
        self.parameter = parameter
        self.multiline = multiline
        _value = State(initialValue: parameter.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.capitalized)
                .font(.headline)

            if parameter.kind == .boolean {
                Toggle("", isOn: Binding(
                    get: { (value as NSString).boolValue },
                    set: { newValue in
                        value = newValue ? "true" : "false"
                        store.setParameter(parameter, value: value)
                    }
                ))
                .labelsHidden()
            } else if multiline && parameter.kind == .text {
                TextEditor(text: $value)
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: value) { _, newValue in
                        store.setParameter(parameter, value: newValue)
                    }
            } else {
                TextField(title, text: $value)
                    .keyboardType(
                        parameter.kind == .integer
                        ? .numbersAndPunctuation
                        : parameter.kind == .decimal
                        ? .decimalPad
                        : .default
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: value) { _, newValue in
                        store.setParameter(parameter, value: newValue)
                    }
            }
        }
        .onChange(of: parameter.value) { _, newValue in
            if value != newValue {
                value = newValue
            }
        }
    }
}

private struct SeedEditor: View {
    @EnvironmentObject private var store: WorkflowStore
    let parameter: WorkflowParameter

    @State private var value: String

    init(parameter: WorkflowParameter) {
        self.parameter = parameter
        _value = State(initialValue: parameter.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Seed")
                .font(.headline)

            HStack(spacing: 10) {
                TextField("Seed", text: $value)
                    .keyboardType(.numbersAndPunctuation)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: value) { _, newValue in
                        store.setParameter(parameter, value: newValue)
                    }

                Button {
                    let random = Int64.random(in: 0...Int64.max)
                    value = String(random)
                    store.setParameter(parameter, value: value)
                } label: {
                    Image(systemName: "dice.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .onChange(of: parameter.value) { _, newValue in
            if value != newValue {
                value = newValue
            }
        }
    }
}

private struct MaterialTile: View {
    @EnvironmentObject private var store: WorkflowStore

    let material: WorkflowMaterial
    let serverURL: String
    let onStatus: (String) -> Void

    @State private var selection: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var uploading = false
    @State private var remoteName: String

    init(
        material: WorkflowMaterial,
        serverURL: String,
        onStatus: @escaping (String) -> Void
    ) {
        self.material = material
        self.serverURL = serverURL
        self.onStatus = onStatus
        _remoteName = State(initialValue: material.currentValue)
    }

    var body: some View {
        VStack(spacing: 5) {
            PhotosPicker(
                selection: $selection,
                matching: material.kind == .image ? .images : .videos
            ) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(.thinMaterial)
                        .frame(width: 78, height: 78)

                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 78, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                    } else {
                        Image(systemName: material.kind == .image ? "photo.badge.plus" : "video.badge.plus")
                            .font(.title2)
                    }

                    if uploading {
                        RoundedRectangle(cornerRadius: 13)
                            .fill(.black.opacity(0.35))
                            .frame(width: 78, height: 78)
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .onChange(of: selection) { _, newItem in
                guard let newItem else { return }
                Task {
                    await importItem(newItem)
                }
            }

            Text(material.nodeTitle)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 82)
        }
    }

    @MainActor
    private func importItem(_ item: PhotosPickerItem) async {
        uploading = true
        defer { uploading = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ComfyClientError.network("Не удалось прочитать выбранный файл")
            }

            let contentType = item.supportedContentTypes.first(where: { type in
                material.kind == .image ? type.conforms(to: .image) : type.conforms(to: .movie)
            })

            let ext = contentType?.preferredFilenameExtension
                ?? (material.kind == .image ? "jpg" : "mp4")
            let mime = contentType?.preferredMIMEType
                ?? (material.kind == .image ? "image/jpeg" : "video/mp4")
            let filename = "comfy_mobile_" + UUID().uuidString + "." + ext

            if material.kind == .image {
                previewImage = UIImage(data: data)
            }

            let uploaded = try await ComfyClient.uploadInput(
                base: serverURL,
                data: data,
                fileName: filename,
                mimeType: mime
            )

            remoteName = uploaded
            store.setMaterial(material, remoteName: uploaded)
        } catch {
            onStatus(error.localizedDescription)
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var store: WorkflowStore
    @Environment(\.dismiss) private var dismiss
    @Binding var serverURL: String

    @State private var showingImporter = false
    @State private var checking = false
    @State private var serverOnline = false
    @State private var connectionMessage = "Не проверено"
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showingAlert = false
    @State private var expandedNodeIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                comfySection
                workflowSection
                nodeSettingsSection
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingImporter) {
                WorkflowDocumentPicker(
                    onPick: { url in
                        showingImporter = false
                        importFile(url)
                    },
                    onCancel: {
                        showingImporter = false
                    }
                )
                .ignoresSafeArea()
            }
            .alert(alertTitle, isPresented: $showingAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    private var comfySection: some View {
        Section("ComfyUI") {
            TextField("192.168.1.25:8188", text: $serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            HStack {
                Circle()
                    .fill(serverOnline ? .green : .red)
                    .frame(width: 9, height: 9)

                Text(connectionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if checking {
                    ProgressView()
                } else {
                    Button("Проверить") {
                        Task {
                            await checkServer()
                        }
                    }
                }
            }

            Button {
                openComfyInBrowser()
            } label: {
                Label("Открыть ComfyUI в Safari", systemImage: "safari")
            }
        }
    }

    private var workflowSection: some View {
        Section("Workflow") {
            if store.workflows.isEmpty {
                Text("Workflow пока не добавлены")
                    .foregroundStyle(.secondary)
            } else {
                Picker(
                    "Выбранный workflow",
                    selection: Binding(
                        get: { store.selectedID ?? store.workflows.first!.id },
                        set: {
                            store.select($0)
                            expandedNodeIDs.removeAll()
                        }
                    )
                ) {
                    ForEach(store.workflows) { item in
                        Text(item.name).tag(item.id)
                    }
                }

                if let item = store.selected {
                    Button(role: .destructive) {
                        store.delete(item)
                    } label: {
                        Label("Удалить выбранный workflow", systemImage: "trash")
                    }
                }
            }

            Button {
                showingImporter = true
            } label: {
                Label("Импорт JSON из «Файлы»", systemImage: "folder.badge.plus")
            }
        }
    }

    @ViewBuilder
    private var nodeSettingsSection: some View {
        if let item = store.selected {
            let groups = store.nodeGroups(for: item)

            Section {
                if groups.isEmpty {
                    Text("Нет доступных параметров нод")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Выбери, что показывать на главном экране")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Свернуть все") {
                            expandedNodeIDs.removeAll()
                        }
                        .font(.caption)
                    }

                    ForEach(groups) { group in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedNodeIDs.contains(group.id) },
                                set: { expanded in
                                    if expanded {
                                        expandedNodeIDs.insert(group.id)
                                    } else {
                                        expandedNodeIDs.remove(group.id)
                                    }
                                }
                            )
                        ) {
                            ForEach(group.parameters) { parameter in
                                NodeSettingRow(
                                    parameter: parameter,
                                    item: item
                                )
                                .environmentObject(store)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title)
                                    .font(.headline)
                                Text(group.classType + " • node " + group.nodeID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Параметры нод")
            }
        }
    }

    private func openComfyInBrowser() {
        guard let url = ComfyClient.normalizedBaseURL(serverURL) else {
            alertTitle = "Неверный адрес"
            alertMessage = "Пример: 192.168.1.25:8188 или 100.x.x.x:8188"
            showingAlert = true
            return
        }

        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                Task { @MainActor in
                    alertTitle = "Ошибка"
                    alertMessage = "Safari не смог открыть адрес ComfyUI"
                    showingAlert = true
                }
            }
        }
    }

    @MainActor
    private func checkServer() async {
        checking = true
        connectionMessage = "Проверяю…"

        let result = await ComfyClient.check(base: serverURL)
        serverOnline = result.online
        connectionMessage = result.message

        if let normalized = result.normalizedURL {
            serverURL = normalized
        }

        checking = false
    }

    private func importFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                throw NSError(
                    domain: "ComfyMobile",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Выбранный файл пустой"]
                )
            }

            try store.importJSON(
                data: data,
                suggestedName: url.deletingPathExtension().lastPathComponent
            )

            expandedNodeIDs.removeAll()
            alertTitle = "Workflow импортирован"
            alertMessage = url.lastPathComponent
            showingAlert = true
        } catch {
            alertTitle = "Не удалось импортировать"
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }
}

private struct NodeSettingRow: View {
    @EnvironmentObject private var store: WorkflowStore

    let parameter: WorkflowParameter
    let item: WorkflowItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(parameter.key)
                    .font(.subheadline.weight(.medium))

                Text(parameter.value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if store.isPinned(parameter, in: item) {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    store.toggleExposed(parameter, in: item)
                } label: {
                    Image(
                        systemName: store.isExposed(parameter, in: item)
                        ? "minus.circle.fill"
                        : "plus.circle"
                    )
                    .font(.title3)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}
