import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

private struct LocalStudioResult: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: ComfyOutputKind
}

struct NativeStudioView: View {
    @EnvironmentObject private var store: WorkflowStore
    @AppStorage("comfyServerURL") private var serverURL = ""

    @State private var showingSettings = false
    @State private var busy = false
    @State private var progress = 0.0
    @State private var statusText = "Не подключено"
    @State private var serverOnline = false
    @State private var alertText = ""
    @State private var showingAlert = false
    @State private var disabledReferenceNodeIDs: Set<String> = []
    @State private var results: [LocalStudioResult] = []
    @State private var currentPromptID: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 18) {
                        header

                        if let item = store.selected {
                            referencesSection(item)
                            promptSection(item)
                            seedSection(item)
                            exposedSection(item)
                            generateSection

                            if !results.isEmpty {
                                resultsSection
                            }
                        } else {
                            emptyWorkflow
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 32)
                }

                if busy {
                    ProgressView(value: progress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(.mint)
                        .frame(height: 2)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("Настройки")
                }
            }
            .sheet(isPresented: $showingSettings) {
                NativeSettingsView(serverURL: $serverURL)
                    .environmentObject(store)
            }
            .alert("Mini Studio", isPresented: $showingAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertText)
            }
            .onAppear {
                Task { await refreshConnection() }
            }
            .onChange(of: store.selectedID) { _ in
                disabledReferenceNodeIDs.removeAll()
                results.removeAll()
            }
        }
        .tint(.mint)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.mint.opacity(0.18))
                        .frame(width: 48, height: 48)
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.title2)
                        .foregroundStyle(.mint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Mini Studio")
                        .font(.title2.bold())
                    Text(store.selected?.name ?? "Native ComfyUI client")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(serverOnline ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(serverOnline ? "ONLINE" : "OFFLINE")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button {
                    Task { await refreshConnection() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func referencesSection(_ item: WorkflowItem) -> some View {
        let materials = sortedMaterials(store.materials(for: item))

        if !materials.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("References")
                        .font(.headline)
                    Spacer()
                    Text("\(materials.count) входов")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(materials) { material in
                            NativeReferenceCard(
                                material: material,
                                role: referenceRole(material.nodeTitle),
                                serverURL: serverURL,
                                enabled: Binding(
                                    get: { !disabledReferenceNodeIDs.contains(material.nodeID) },
                                    set: { enabled in
                                        if enabled {
                                            disabledReferenceNodeIDs.remove(material.nodeID)
                                        } else {
                                            disabledReferenceNodeIDs.insert(material.nodeID)
                                        }
                                    }
                                ),
                                onStatus: showMessage
                            )
                            .environmentObject(store)
                        }
                    }
                }

                Text("Bypass отключает выбранный reference в API prompt перед отправкой в ComfyUI.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func promptSection(_ item: WorkflowItem) -> some View {
        if let prompt = store.primaryPromptParameter(for: item) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt")
                    .font(.headline)
                NativeParameterEditor(parameter: prompt, multiline: true)
                    .environmentObject(store)
            }
        }
    }

    @ViewBuilder
    private func seedSection(_ item: WorkflowItem) -> some View {
        if let seed = store.primarySeedParameter(for: item) {
            NativeSeedEditor(parameter: seed)
                .environmentObject(store)
        }
    }

    @ViewBuilder
    private func exposedSection(_ item: WorkflowItem) -> some View {
        let extra = store.exposedParameters(for: item)
        if !extra.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick settings")
                    .font(.headline)

                ForEach(extra) { parameter in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(parameter.key.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.subheadline.weight(.semibold))
                        NativeParameterEditor(parameter: parameter, multiline: false)
                            .environmentObject(store)
                    }
                }
            }
        }
    }

    private var generateSection: some View {
        VStack(spacing: 10) {
            if busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Генерация выполняется на ПК")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await generate() }
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "sparkles")
                        Text("GENERATE")
                            .font(.headline.bold())
                        Spacer()
                    }
                    .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)
                .foregroundStyle(.black)
                .disabled(busy || store.selected?.apiPromptJSON == nil)

                if busy {
                    Button(role: .destructive) {
                        Task { await stopGeneration() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.top, 2)
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Results")
                    .font(.headline)
                Spacer()
                Text("\(results.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(results) { result in
                ResultCard(result: result)
            }
        }
    }

    private var emptyWorkflow: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 52))
                .foregroundStyle(.mint)
            Text("Добавь workflow")
                .font(.title2.bold())
            Text("В настройках импортируй ComfyUI JSON в API Format. После этого приложение само покажет references, prompt, seed и выбранные параметры.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Открыть настройки") {
                showingSettings = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 70)
        .frame(maxWidth: .infinity)
    }

    private func sortedMaterials(_ materials: [WorkflowMaterial]) -> [WorkflowMaterial] {
        materials.sorted { a, b in
            let ai = pictureIndex(a.nodeTitle) ?? 10_000
            let bi = pictureIndex(b.nodeTitle) ?? 10_000
            if ai == bi {
                return a.nodeTitle.localizedStandardCompare(b.nodeTitle) == .orderedAscending
            }
            return ai < bi
        }
    }

    private func pictureIndex(_ title: String) -> Int? {
        let lower = title.lowercased()
        guard let range = lower.range(of: "picture") else { return nil }
        let tail = lower[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }

    private func referenceRole(_ title: String) -> String {
        switch pictureIndex(title) {
        case 1: return "Лицо · персонаж 1"
        case 2: return "Тело · персонаж 1"
        case 3: return "Лицо · персонаж 2"
        case 4: return "Тело · персонаж 2"
        case 5: return "Первый кадр"
        case 6: return "Деталь 1"
        case 7: return "Деталь 2"
        case 8: return "Деталь 3"
        case 9: return "Деталь 4"
        default: return title
        }
    }

    private func showMessage(_ text: String) {
        alertText = text
        showingAlert = true
    }

    @MainActor
    private func refreshConnection() async {
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            serverOnline = false
            statusText = "Укажи адрес ComfyUI в настройках"
            return
        }

        statusText = "Проверяю ComfyUI…"
        let result = await ComfyClient.check(base: serverURL)
        serverOnline = result.online
        statusText = result.message
        if let normalized = result.normalizedURL {
            serverURL = normalized
        }
    }

    @MainActor
    private func generate() async {
        guard let prompt = store.preparedPrompt(disabledNodeIDs: disabledReferenceNodeIDs) else {
            showMessage("У выбранного workflow нет API prompt. Импортируй JSON через Save (API Format).")
            return
        }

        busy = true
        progress = 0.03
        results.removeAll()
        statusText = "Отправляю workflow…"

        do {
            let promptID = try await ComfyClient.queue(base: serverURL, prompt: prompt)
            currentPromptID = promptID
            serverOnline = true
            statusText = "В очереди • \(promptID.prefix(8))"
            progress = 0.08

            var finished = false
            var checks = 0

            while busy && !finished && checks < 7200 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                checks += 1

                finished = try await ComfyClient.generationFinished(
                    base: serverURL,
                    promptID: promptID
                )

                if finished {
                    progress = 0.96
                    statusText = "Получаю результат…"
                    let files = try await ComfyClient.resultFiles(base: serverURL, promptID: promptID)
                    results = try await saveResults(files)
                    progress = 1
                    statusText = results.isEmpty ? "Готово • output сохранён на ПК" : "Готово • \(results.count) результат(а)"
                } else {
                    let remaining = max(0, 0.92 - progress)
                    progress = min(0.92, progress + max(0.002, remaining * 0.025))
                }
            }

            if !finished && busy {
                statusText = "Генерация ещё выполняется на ПК"
            }
        } catch {
            statusText = "Ошибка"
            showMessage(error.localizedDescription)
        }

        busy = false
        currentPromptID = nil
        if progress >= 1 {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        progress = 0
    }

    @MainActor
    private func stopGeneration() async {
        do {
            try await ComfyClient.interrupt(base: serverURL)
            statusText = "Остановлено"
        } catch {
            showMessage(error.localizedDescription)
        }
        busy = false
        currentPromptID = nil
        progress = 0
    }

    private func saveResults(_ files: [ComfyOutputFile]) async throws -> [LocalStudioResult] {
        guard !files.isEmpty else { return [] }

        let fm = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mini Studio Results", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        var saved: [LocalStudioResult] = []

        for file in files {
            let data = try await ComfyClient.resultData(base: serverURL, file: file)
            let safeName = (file.filename as NSString).lastPathComponent
            var destination = base.appendingPathComponent(safeName)

            if fm.fileExists(atPath: destination.path) {
                destination = base.appendingPathComponent(
                    UUID().uuidString.prefix(8) + "-" + safeName
                )
            }

            try data.write(to: destination, options: [.atomic])
            saved.append(LocalStudioResult(url: destination, kind: file.kind))
        }

        return saved
    }
}

private struct NativeReferenceCard: View {
    @EnvironmentObject private var store: WorkflowStore

    let material: WorkflowMaterial
    let role: String
    let serverURL: String
    @Binding var enabled: Bool
    let onStatus: (String) -> Void

    @State private var selection: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var uploading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PhotosPicker(
                selection: $selection,
                matching: material.kind == .image ? .images : .videos
            ) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .frame(width: 116, height: 116)

                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 116, height: 116)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        VStack(spacing: 7) {
                            Image(systemName: material.kind == .image ? "photo.badge.plus" : "video.badge.plus")
                                .font(.title2)
                            Text(material.nodeTitle)
                                .font(.caption2.bold())
                                .lineLimit(1)
                        }
                        .foregroundStyle(enabled ? Color.primary : Color.secondary)
                    }

                    if !enabled {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black.opacity(0.55))
                            .frame(width: 116, height: 116)
                        Text("BYPASS")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }

                    if uploading {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 116, height: 116)
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .disabled(!enabled || uploading)
            .onChange(of: selection) { newItem in
                guard let newItem else { return }
                Task { await importItem(newItem) }
            }

            Text(role)
                .font(.caption)
                .lineLimit(2)
                .frame(width: 116, alignment: .leading)

            Toggle("Use", isOn: $enabled)
                .font(.caption2)
                .toggleStyle(.switch)
                .frame(width: 116)
        }
        .padding(9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    @MainActor
    private func importItem(_ item: PhotosPickerItem) async {
        guard !serverURL.isEmpty else {
            onStatus("Сначала укажи адрес ComfyUI в настройках.")
            return
        }

        uploading = true
        defer { uploading = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ComfyClientError.network("Не удалось прочитать выбранный файл")
            }

            let contentType = item.supportedContentTypes.first(where: { type in
                material.kind == .image ? type.conforms(to: .image) : type.conforms(to: .movie)
            })
            let ext = contentType?.preferredFilenameExtension ?? (material.kind == .image ? "jpg" : "mp4")
            let mime = contentType?.preferredMIMEType ?? (material.kind == .image ? "image/jpeg" : "video/mp4")
            let filename = "mini_studio_" + UUID().uuidString + "." + ext

            if material.kind == .image {
                previewImage = UIImage(data: data)
            }

            let remote = try await ComfyClient.uploadInput(
                base: serverURL,
                data: data,
                fileName: filename,
                mimeType: mime
            )

            store.setMaterial(material, remoteName: remote)
        } catch {
            onStatus(error.localizedDescription)
        }
    }
}

private struct NativeParameterEditor: View {
    @EnvironmentObject private var store: WorkflowStore
    let parameter: WorkflowParameter
    let multiline: Bool

    @State private var value: String

    init(parameter: WorkflowParameter, multiline: Bool) {
        self.parameter = parameter
        self.multiline = multiline
        _value = State(initialValue: parameter.value)
    }

    var body: some View {
        Group {
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
                    .frame(minHeight: 130)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .onChange(of: value) { newValue in
                        store.setParameter(parameter, value: newValue)
                    }
            } else {
                TextField(parameter.key, text: $value)
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
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onChange(of: value) { newValue in
                        store.setParameter(parameter, value: newValue)
                    }
            }
        }
        .onChange(of: parameter.value) { newValue in
            if value != newValue { value = newValue }
        }
    }
}

private struct NativeSeedEditor: View {
    @EnvironmentObject private var store: WorkflowStore
    let parameter: WorkflowParameter

    @State private var value: String

    init(parameter: WorkflowParameter) {
        self.parameter = parameter
        _value = State(initialValue: parameter.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Seed")
                .font(.headline)
            HStack(spacing: 10) {
                TextField("Seed", text: $value)
                    .keyboardType(.numbersAndPunctuation)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onChange(of: value) { newValue in
                        store.setParameter(parameter, value: newValue)
                    }

                Button {
                    value = String(Int64.random(in: 0...Int64.max))
                    store.setParameter(parameter, value: value)
                } label: {
                    Image(systemName: "dice.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .onChange(of: parameter.value) { newValue in
            if value != newValue { value = newValue }
        }
    }
}

private struct ResultCard: View {
    let result: LocalStudioResult

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .frame(width: 82, height: 82)

                if result.kind == .image,
                   let image = UIImage(contentsOfFile: result.url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 82, height: 82)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(systemName: iconName)
                        .font(.title2)
                        .foregroundStyle(.mint)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(result.url.lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(result.kind.rawValue.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ShareLink(item: result.url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var iconName: String {
        switch result.kind {
        case .image: return "photo"
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        case .file: return "doc.fill"
        }
    }
}

private struct NativeSettingsView: View {
    @EnvironmentObject private var store: WorkflowStore
    @Environment(\.dismiss) private var dismiss
    @Binding var serverURL: String

    @State private var showingImporter = false
    @State private var checking = false
    @State private var online = false
    @State private var connectionMessage = "Не проверено"
    @State private var alertText = ""
    @State private var showingAlert = false
    @State private var expandedNodeIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section("ComfyUI backend") {
                    TextField("100.x.x.x:8188", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Circle()
                            .fill(online ? Color.green : Color.red)
                            .frame(width: 9, height: 9)
                        Text(connectionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if checking {
                            ProgressView()
                        } else {
                            Button("Проверить") {
                                Task { await checkServer() }
                            }
                        }
                    }

                    Text("ComfyUI здесь только backend: приложение не показывает его интерфейс. Нужны API /prompt, /history, /view и /upload/image.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Workflow") {
                    if store.workflows.isEmpty {
                        Text("Нет импортированных workflow")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(
                            "Активный",
                            selection: Binding(
                                get: { store.selectedID ?? store.workflows[0].id },
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

                        if let selected = store.selected {
                            Button(role: .destructive) {
                                store.delete(selected)
                            } label: {
                                Label("Удалить workflow", systemImage: "trash")
                            }
                        }
                    }

                    Button {
                        showingImporter = true
                    } label: {
                        Label("Импорт API JSON", systemImage: "doc.badge.plus")
                    }

                    Text("Лучший вариант: в ComfyUI выбери Save (API Format) и импортируй этот JSON. Нативный интерфейс автоматически найдёт LoadImage/Picture, prompt, seed и остальные inputs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let item = store.selected {
                    Section("Поля на главном экране") {
                        let groups = store.nodeGroups(for: item)
                        if groups.isEmpty {
                            Text("Нет доступных параметров")
                                .foregroundStyle(.secondary)
                        } else {
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
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(parameter.key)
                                                Text(parameter.value)
                                                    .font(.caption2)
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
                                                }
                                                .buttonStyle(.borderless)
                                            }
                                        }
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.title)
                                            .font(.subheadline.weight(.semibold))
                                        Text(group.classType + " • node " + group.nodeID)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Mini Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(isPresented: $showingImporter) {
                WorkflowDocumentPicker(
                    onPick: { url in
                        showingImporter = false
                        importWorkflow(url)
                    },
                    onCancel: { showingImporter = false }
                )
                .ignoresSafeArea()
            }
            .alert("Mini Studio", isPresented: $showingAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertText)
            }
        }
    }

    @MainActor
    private func checkServer() async {
        checking = true
        connectionMessage = "Проверяю…"
        let result = await ComfyClient.check(base: serverURL)
        online = result.online
        connectionMessage = result.message
        if let normalized = result.normalizedURL {
            serverURL = normalized
        }
        checking = false
    }

    private func importWorkflow(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            try store.importJSON(
                data: data,
                suggestedName: url.deletingPathExtension().lastPathComponent
            )

            guard store.selected?.apiPromptJSON != nil else {
                alertText = "JSON импортирован, но это UI workflow. Для Generate нужен Save (API Format) JSON."
                showingAlert = true
                return
            }

            alertText = "API workflow импортирован"
            showingAlert = true
        } catch {
            alertText = error.localizedDescription
            showingAlert = true
        }
    }
}
