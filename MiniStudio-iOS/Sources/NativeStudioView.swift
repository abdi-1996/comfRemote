import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AVKit

private enum StudioTab: Hashable {
    case generate
    case references
    case results
    case settings
}

private struct LocalStudioResult: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: ComfyOutputKind
}

struct NativeStudioView: View {
    @EnvironmentObject private var store: WorkflowStore
    @AppStorage("comfyServerURL") private var serverURL = ""

    @State private var selectedTab: StudioTab = .generate
    @State private var busy = false
    @State private var progress = 0.0
    @State private var statusText = "Не подключено"
    @State private var serverOnline = false
    @State private var alertText = ""
    @State private var showingAlert = false
    @State private var disabledReferenceNodeIDs: Set<String> = []
    @State private var referencePreviews: [String: UIImage] = [:]
    @State private var results: [LocalStudioResult] = []
    @State private var selectedResult: LocalStudioResult?
    @State private var currentPromptID: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                generateScreen
                    .navigationTitle("Mini Studio")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { connectionToolbar }
            }
            .tabItem {
                Label("Generate", systemImage: "sparkles")
            }
            .tag(StudioTab.generate)

            NavigationStack {
                referencesScreen
                    .navigationTitle("References")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { connectionToolbar }
            }
            .tabItem {
                Label("References", systemImage: "person.2.crop.square.stack")
            }
            .tag(StudioTab.references)

            NavigationStack {
                resultsScreen
                    .navigationTitle("Results")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { connectionToolbar }
            }
            .tabItem {
                Label("Results", systemImage: "photo.stack")
            }
            .tag(StudioTab.results)

            NavigationStack {
                settingsScreen
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(StudioTab.settings)
        }
        .tint(.mint)
        .preferredColorScheme(.dark)
        .alert("Mini Studio", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertText)
        }
        .sheet(item: $selectedResult) { result in
            ResultDetailView(result: result)
        }
        .onAppear {
            loadSavedResults()
            Task { await refreshConnection() }
        }
        .onChange(of: store.selectedID) { _ in
            disabledReferenceNodeIDs.removeAll()
            referencePreviews.removeAll()
        }
    }

    @ToolbarContentBuilder
    private var connectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await refreshConnection() }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(serverOnline ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(serverOnline ? "Online" : "Offline")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var generateScreen: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 16) {
                    studioHero

                    if let item = store.selected {
                        quickStatus(item)
                        latestResultPanel
                        promptPanel(item)
                        seedAndQuickPanel(item)
                        generateControls
                    } else {
                        noWorkflowPanel
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(studioBackground)

            if busy {
                ProgressView(value: progress, total: 1)
                    .progressViewStyle(.linear)
                    .tint(.mint)
                    .frame(height: 2)
            }
        }
    }

    private var referencesScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let item = store.selected {
                    let materials = sortedMaterials(store.materials(for: item))

                    referencesHeader(materials)

                    if materials.isEmpty {
                        infoPanel(
                            icon: "photo.on.rectangle.angled",
                            title: "References не найдены",
                            text: "В API workflow должны быть LoadImage / Picture inputs."
                        )
                    } else {
                        referenceGroup(
                            title: "Персонаж 1",
                            subtitle: "Лицо и тело",
                            materials: materials.filter { [1, 2].contains(pictureIndex($0.nodeTitle) ?? -1) }
                        )

                        referenceGroup(
                            title: "Персонаж 2",
                            subtitle: "Лицо и тело",
                            materials: materials.filter { [3, 4].contains(pictureIndex($0.nodeTitle) ?? -1) }
                        )

                        referenceGroup(
                            title: "Кадр и детали",
                            subtitle: "Picture 5–9",
                            materials: materials.filter {
                                guard let index = pictureIndex($0.nodeTitle) else { return false }
                                return index >= 5 && index <= 9
                            }
                        )

                        let other = materials.filter { pictureIndex($0.nodeTitle) == nil }
                        if !other.isEmpty {
                            referenceGroup(
                                title: "Другие входы",
                                subtitle: "Дополнительные материалы workflow",
                                materials: other
                            )
                        }
                    }
                } else {
                    noWorkflowPanel
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
        .background(studioBackground)
    }

    private var resultsScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Галерея")
                            .font(.title2.bold())
                        Text("Результаты сохраняются на iPhone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !results.isEmpty {
                        Button(role: .destructive) {
                            clearSavedResults()
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if results.isEmpty {
                    infoPanel(
                        icon: "photo.stack",
                        title: "Пока пусто",
                        text: "После генерации фото, видео и аудио появятся здесь автоматически."
                    )
                    .padding(.top, 40)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)
                        ],
                        spacing: 12
                    ) {
                        ForEach(results) { result in
                            ResultGridTile(result: result)
                                .onTapGesture {
                                    selectedResult = result
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
        .background(studioBackground)
    }

    private var settingsScreen: some View {
        NativeSettingsTab(
            serverURL: $serverURL,
            serverOnline: $serverOnline,
            statusText: $statusText,
            onMessage: showMessage
        )
        .environmentObject(store)
        .background(studioBackground)
    }

    private var studioBackground: some View {
        LinearGradient(
            colors: [
                Color.black,
                Color(red: 0.025, green: 0.06, blue: 0.055),
                Color.black
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var studioHero: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.mint.opacity(0.28),
                                Color.cyan.opacity(0.09)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 62, height: 62)

                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.mint)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(store.selected?.name ?? "Mini Studio Native")
                    .font(.title3.bold())
                    .lineLimit(1)

                HStack(spacing: 8) {
                    statusDot
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private var statusDot: some View {
        Circle()
            .fill(serverOnline ? Color.green : Color.red)
            .frame(width: 7, height: 7)
    }

    @ViewBuilder
    private func quickStatus(_ item: WorkflowItem) -> some View {
        let materials = sortedMaterials(store.materials(for: item))
        let active = materials.filter { !disabledReferenceNodeIDs.contains($0.nodeID) }.count

        HStack(spacing: 10) {
            QuickStat(
                icon: "photo.on.rectangle.angled",
                value: "\(active)/\(materials.count)",
                label: "Refs"
            )

            QuickStat(
                icon: "cpu",
                value: serverOnline ? "Ready" : "Offline",
                label: "Backend"
            )

            QuickStat(
                icon: "clock.arrow.circlepath",
                value: busy ? "\(Int(progress * 100))%" : "Idle",
                label: "Status"
            )
        }
    }

    private var latestResultPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(results.isEmpty ? "Preview" : "Последний результат")
                    .font(.headline)

                Spacer()

                if !results.isEmpty {
                    Button("Все") {
                        selectedTab = .results
                    }
                    .font(.caption.bold())
                }
            }

            if let result = results.first {
                Button {
                    selectedResult = result
                } label: {
                    LatestResultPreview(result: result)
                }
                .buttonStyle(.plain)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(0.045))
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)

                    VStack(spacing: 10) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.system(size: 38))
                            .foregroundStyle(.mint.opacity(0.75))
                        Text("Результат появится здесь")
                            .font(.subheadline.weight(.semibold))
                        Text("Фото · Видео · Аудио")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 22))
    }

    @ViewBuilder
    private func promptPanel(_ item: WorkflowItem) -> some View {
        if let prompt = store.primaryPromptParameter(for: item) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Prompt", systemImage: "text.alignleft")
                        .font(.headline)

                    Spacer()

                    Text("\(prompt.value.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                NativeParameterEditor(parameter: prompt, multiline: true)
                    .environmentObject(store)
            }
            .padding(14)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    @ViewBuilder
    private func seedAndQuickPanel(_ item: WorkflowItem) -> some View {
        let extra = store.exposedParameters(for: item)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Quick")
                    .font(.headline)
                Spacer()
                Button {
                    selectedTab = .settings
                } label: {
                    Label("Настроить", systemImage: "slider.horizontal.3")
                        .font(.caption.bold())
                }
            }

            if let seed = store.primarySeedParameter(for: item) {
                NativeSeedEditor(parameter: seed)
                    .environmentObject(store)
            }

            if !extra.isEmpty {
                Divider().opacity(0.5)

                ForEach(extra.prefix(5)) { parameter in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayName(parameter.key))
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        NativeParameterEditor(parameter: parameter, multiline: false)
                            .environmentObject(store)
                    }
                }

                if extra.count > 5 {
                    Button("Ещё \(extra.count - 5) параметров") {
                        selectedTab = .settings
                    }
                    .font(.caption.bold())
                }
            }
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 22))
    }

    private var generateControls: some View {
        VStack(spacing: 10) {
            if busy {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.mint)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Генерация на ПК")
                            .font(.subheadline.bold())
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text("\(Int(progress * 100))%")
                        .font(.headline.monospacedDigit())
                }
                .padding(12)
                .background(Color.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            }

            HStack(spacing: 10) {
                Button {
                    Task { await generate() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: busy ? "hourglass" : "sparkles")
                        Text(busy ? "GENERATING" : "GENERATE")
                            .font(.headline.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
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
                            .font(.headline)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !serverOnline {
                Button {
                    selectedTab = .settings
                } label: {
                    Label("Настроить подключение к ComfyUI", systemImage: "network")
                        .font(.caption.bold())
                }
            }
        }
    }

    private var noWorkflowPanel: some View {
        infoPanel(
            icon: "point.3.connected.trianglepath.dotted",
            title: "Workflow не выбран",
            text: "Импортируй ComfyUI Save (API Format) JSON. После этого Mini Studio сам найдёт prompt, seed, references и параметры."
        )
        .overlay(alignment: .bottom) {
            Button("Открыть Settings") {
                selectedTab = .settings
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .foregroundStyle(.black)
            .padding(.bottom, 18)
        }
        .padding(.top, 60)
    }

    @ViewBuilder
    private func referencesHeader(_ materials: [WorkflowMaterial]) -> some View {
        let active = materials.filter { !disabledReferenceNodeIDs.contains($0.nodeID) }.count

        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reference Board")
                    .font(.title2.bold())
                Text("Активно \(active) из \(materials.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                disabledReferenceNodeIDs.removeAll()
            } label: {
                Label("All", systemImage: "checkmark.circle")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func referenceGroup(
        title: String,
        subtitle: String,
        materials: [WorkflowMaterial]
    ) -> some View {
        if !materials.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 145), spacing: 12)
                    ],
                    spacing: 12
                ) {
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
                            previewImage: Binding(
                                get: { referencePreviews[material.id] },
                                set: { referencePreviews[material.id] = $0 }
                            ),
                            onStatus: showMessage
                        )
                        .environmentObject(store)
                    }
                }
            }
        }
    }

    private var cardBackground: Color {
        Color.white.opacity(0.055)
    }

    private func infoPanel(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.mint)
            Text(title)
                .font(.title3.bold())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 22))
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
        let numericStart = tail.firstIndex(where: { $0.isNumber })
        guard let numericStart else { return nil }
        let digits = tail[numericStart...].prefix { $0.isNumber }
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

    private func displayName(_ key: String) -> String {
        key
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .capitalized
    }

    private func showMessage(_ text: String) {
        alertText = text
        showingAlert = true
    }

    @MainActor
    private func refreshConnection() async {
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            serverOnline = false
            statusText = "Укажи адрес ComfyUI в Settings"
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
        guard serverOnline else {
            showMessage("ComfyUI offline. Проверь адрес во вкладке Settings.")
            selectedTab = .settings
            return
        }

        guard let prompt = store.preparedPrompt(disabledNodeIDs: disabledReferenceNodeIDs) else {
            showMessage("У выбранного workflow нет API prompt. Импортируй Save (API Format) JSON.")
            return
        }

        busy = true
        progress = 0.03
        statusText = "Отправляю workflow…"

        do {
            let promptID = try await ComfyClient.queue(base: serverURL, prompt: prompt)
            currentPromptID = promptID
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

                    let files = try await ComfyClient.resultFiles(
                        base: serverURL,
                        promptID: promptID
                    )
                    let newResults = try await saveResults(files)

                    results.insert(contentsOf: newResults, at: 0)
                    progress = 1
                    statusText = newResults.isEmpty
                        ? "Готово • output сохранён на ПК"
                        : "Готово • \(newResults.count) результат(а)"
                } else {
                    let remaining = max(0, 0.92 - progress)
                    progress = min(0.92, progress + max(0.002, remaining * 0.025))
                }
            }

            if !finished && busy {
                statusText = "Генерация ещё выполняется на ПК"
            }
        } catch {
            statusText = "Ошибка генерации"
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
        let base = resultsDirectory
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        var saved: [LocalStudioResult] = []

        for file in files {
            let data = try await ComfyClient.resultData(base: serverURL, file: file)
            let safeName = (file.filename as NSString).lastPathComponent
            var destination = base.appendingPathComponent(safeName)

            if fm.fileExists(atPath: destination.path) {
                destination = base.appendingPathComponent(
                    String(UUID().uuidString.prefix(8)) + "-" + safeName
                )
            }

            try data.write(to: destination, options: [.atomic])
            saved.append(LocalStudioResult(url: destination, kind: file.kind))
        }

        return saved
    }

    private var resultsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mini Studio Results", isDirectory: true)
    }

    private func loadSavedResults() {
        let fm = FileManager.default
        try? fm.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)

        let urls = (
            try? fm.contentsOfDirectory(
                at: resultsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        ) ?? []

        results = urls
            .filter { !$0.hasDirectoryPath }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .map {
                LocalStudioResult(url: $0, kind: resultKind(for: $0))
            }
    }

    private func clearSavedResults() {
        let fm = FileManager.default

        for result in results {
            try? fm.removeItem(at: result.url)
        }

        results.removeAll()
    }

    private func resultKind(for url: URL) -> ComfyOutputKind {
        let ext = url.pathExtension.lowercased()

        if ["png", "jpg", "jpeg", "webp", "gif", "bmp"].contains(ext) {
            return .image
        }

        if ["mp4", "mov", "m4v", "webm", "mkv"].contains(ext) {
            return .video
        }

        if ["wav", "mp3", "m4a", "aac", "flac", "ogg"].contains(ext) {
            return .audio
        }

        return .file
    }
}

private struct QuickStat: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(.mint)
            Text(value)
                .font(.subheadline.bold())
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct NativeReferenceCard: View {
    @EnvironmentObject private var store: WorkflowStore

    let material: WorkflowMaterial
    let role: String
    let serverURL: String
    @Binding var enabled: Bool
    @Binding var previewImage: UIImage?
    let onStatus: (String) -> Void

    @State private var selection: PhotosPickerItem?
    @State private var uploading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PhotosPicker(
                selection: $selection,
                matching: material.kind == .image ? .images : .videos
            ) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.06))
                        .aspectRatio(1, contentMode: .fit)

                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFill()
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: material.kind == .image ? "photo.badge.plus" : "video.badge.plus")
                                .font(.title2)
                            Text("Добавить")
                                .font(.caption.bold())
                        }
                        .foregroundStyle(.mint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    Text(material.nodeTitle)
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(7)

                    if !enabled {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black.opacity(0.62))
                        VStack(spacing: 7) {
                            Image(systemName: "nosign")
                                .font(.title2)
                            Text("BYPASS")
                                .font(.caption.bold())
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if uploading {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black.opacity(0.55))
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!enabled || uploading)
            .onChange(of: selection) { newItem in
                guard let newItem else { return }
                Task { await importItem(newItem) }
            }

            Text(role)
                .font(.caption.bold())
                .lineLimit(2)

            HStack {
                Text(enabled ? "Active" : "Bypass")
                    .font(.caption2)
                    .foregroundStyle(enabled ? .mint : .secondary)

                Spacer()

                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .scaleEffect(0.82)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 19))
        .overlay(
            RoundedRectangle(cornerRadius: 19)
                .stroke(enabled ? Color.mint.opacity(0.18) : Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    @MainActor
    private func importItem(_ item: PhotosPickerItem) async {
        guard !serverURL.isEmpty else {
            onStatus("Сначала укажи адрес ComfyUI во вкладке Settings.")
            return
        }

        uploading = true
        defer { uploading = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ComfyClientError.network("Не удалось прочитать выбранный файл")
            }

            let contentType = item.supportedContentTypes.first(where: { type in
                material.kind == .image
                    ? type.conforms(to: .image)
                    : type.conforms(to: .movie)
            })

            let ext = contentType?.preferredFilenameExtension
                ?? (material.kind == .image ? "jpg" : "mp4")

            let mime = contentType?.preferredMIMEType
                ?? (material.kind == .image ? "image/jpeg" : "video/mp4")

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
                    .frame(minHeight: 128)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    )
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
                    .background(Color.white.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onChange(of: value) { newValue in
                        store.setParameter(parameter, value: newValue)
                    }
            }
        }
        .onChange(of: parameter.value) { newValue in
            if value != newValue {
                value = newValue
            }
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
        VStack(alignment: .leading, spacing: 7) {
            Text("Seed")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("Seed", text: $value)
                    .keyboardType(.numbersAndPunctuation)
                    .padding(12)
                    .background(Color.white.opacity(0.045))
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
            if value != newValue {
                value = newValue
            }
        }
    }
}

private struct LatestResultPreview: View {
    let result: LocalStudioResult

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.045))
                .aspectRatio(16.0 / 10.0, contentMode: .fit)

            switch result.kind {
            case .image:
                if let image = UIImage(contentsOfFile: result.url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .aspectRatio(16.0 / 10.0, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }

            case .video:
                VStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.mint)
                    Text(result.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

            case .audio:
                VStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.mint)
                    Text(result.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

            case .file:
                VStack(spacing: 10) {
                    Image(systemName: "doc.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.mint)
                    Text(result.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}

private struct ResultGridTile: View {
    let result: LocalStudioResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.05))
                    .aspectRatio(1, contentMode: .fit)

                if result.kind == .image,
                   let image = UIImage(contentsOfFile: result.url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 36))
                        .foregroundStyle(.mint)
                }

                if result.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white)
                        .shadow(radius: 6)
                }
            }

            Text(result.url.lastPathComponent)
                .font(.caption.bold())
                .lineLimit(1)

            HStack {
                Text(result.kind.rawValue.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    private var icon: String {
        switch result.kind {
        case .image: return "photo"
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        case .file: return "doc.fill"
        }
    }
}

private struct ResultDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let result: LocalStudioResult

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 0)

                switch result.kind {
                case .image:
                    if let image = UIImage(contentsOfFile: result.url.path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .padding(.horizontal)
                    }

                case .video:
                    VideoPlayer(player: AVPlayer(url: result.url))
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .padding(.horizontal)

                case .audio:
                    VStack(spacing: 16) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 86))
                            .foregroundStyle(.mint)
                        Text("Audio result")
                            .font(.title3.bold())
                    }

                case .file:
                    VStack(spacing: 16) {
                        Image(systemName: "doc.circle.fill")
                            .font(.system(size: 86))
                            .foregroundStyle(.mint)
                        Text(result.url.lastPathComponent)
                            .font(.headline)
                    }
                }

                Text(result.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal)

                ShareLink(item: result.url) {
                    Label("Поделиться / сохранить", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)
                .foregroundStyle(.black)
                .padding(.horizontal)

                Spacer(minLength: 0)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct NativeSettingsTab: View {
    @EnvironmentObject private var store: WorkflowStore

    @Binding var serverURL: String
    @Binding var serverOnline: Bool
    @Binding var statusText: String
    let onMessage: (String) -> Void

    @State private var showingImporter = false
    @State private var checking = false
    @State private var expandedNodeIDs: Set<String> = []

    var body: some View {
        Form {
            Section("ComfyUI Backend") {
                TextField("100.x.x.x:8188", text: $serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack(spacing: 10) {
                    Circle()
                        .fill(serverOnline ? Color.green : Color.red)
                        .frame(width: 9, height: 9)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(serverOnline ? "Connected" : "Not connected")
                            .font(.subheadline.bold())
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    if checking {
                        ProgressView()
                    } else {
                        Button("Проверить") {
                            Task { await checkServer() }
                        }
                    }
                }

                Text("ComfyUI работает только как backend. Интерфейс ComfyUI внутри приложения не используется.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Workflow") {
                if store.workflows.isEmpty {
                    Text("Нет импортированных workflow")
                        .foregroundStyle(.secondary)
                } else {
                    Picker(
                        "Активный workflow",
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
                        Text(selected.apiPromptJSON == nil ? "Нужен API Format JSON" : "API Format готов")
                            .font(.caption)
                            .foregroundStyle(selected.apiPromptJSON == nil ? .orange : .green)

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

                Text("В ComfyUI используй Save (API Format). Mini Studio автоматически найдёт references, prompt, seed и inputs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let item = store.selected {
                Section("Quick Settings") {
                    Text("Нажми + у параметра — он появится на вкладке Generate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(parameter.key)
                                                .font(.subheadline.weight(.medium))
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
                                                        : "plus.circle.fill"
                                                )
                                                .font(.title3)
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                    .padding(.vertical, 3)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title)
                                        .font(.subheadline.bold())
                                    Text(group.classType + " • node " + group.nodeID)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section("Mini Studio 1.2") {
                Label("Нативный SwiftUI интерфейс", systemImage: "iphone")
                Label("ComfyUI API backend", systemImage: "network")
                Label("Persistent Results gallery", systemImage: "photo.stack")
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showingImporter) {
            WorkflowDocumentPicker(
                onPick: { url in
                    showingImporter = false
                    importWorkflow(url)
                },
                onCancel: {
                    showingImporter = false
                }
            )
            .ignoresSafeArea()
        }
    }

    @MainActor
    private func checkServer() async {
        checking = true
        statusText = "Проверяю…"

        let result = await ComfyClient.check(base: serverURL)
        serverOnline = result.online
        statusText = result.message

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

            if store.selected?.apiPromptJSON == nil {
                onMessage("JSON импортирован, но это UI workflow. Для Generate нужен Save (API Format) JSON.")
            } else {
                onMessage("API workflow импортирован")
            }
        } catch {
            onMessage(error.localizedDescription)
        }
    }
}
