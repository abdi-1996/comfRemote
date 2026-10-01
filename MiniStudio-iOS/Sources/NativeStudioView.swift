import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AVKit
import WebKit

private extension Color {
    static let miniStudioAccent = Color(red: 197.0/255.0, green: 242.0/255.0, blue: 119.0/255.0)
}

private enum MiniStudioPanel: String, CaseIterable, Identifiable {
    case generation = "Generate"
    case references = "References"
    case controls = "Controls"
    case models = "Models & LoRAs"
    case gallery = "Gallery"
    case workflows = "Workflows"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .generation: return "sparkles"
        case .references: return "photo.on.rectangle.angled"
        case .controls: return "slider.horizontal.3"
        case .models: return "square.stack.3d.up"
        case .gallery: return "rectangle.stack"
        case .workflows: return "point.3.connected.trianglepath.dotted"
        case .settings: return "gearshape"
        }
    }
}

private struct LocalStudioResult: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: ComfyOutputKind
}

struct NativeStudioView: View {
    @EnvironmentObject private var store: WorkflowStore
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("comfyServerURL") private var serverURL = ""

    @State private var panel: MiniStudioPanel = .generation
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
    @State private var showingImporter = false
    @State private var expandedNodeIDs: Set<String> = []
    @State private var checkingServer = false
    @State private var syncing = false
    @State private var lastHistoryPromptID = ""
    @State private var showingComfyEditor = false
    @StateObject private var comfyBridge = ComfyFrontendBridge()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                studioBackground

                VStack(spacing: 0) {
                    studioHeader
                    panelPicker
                    panelContent
                }

                if busy {
                    ProgressView(value: progress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(Color.miniStudioAccent)
                        .frame(height: 2)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedResult) { result in
                ResultDetailView(result: result)
            }
            .fullScreenCover(isPresented: $showingComfyEditor, onDismiss: {
                Task { await syncWorkflowFromFrontend() }
            }) {
                EmbeddedComfyEditor(bridge: comfyBridge) {
                    await syncWorkflowFromFrontend()
                }
            }
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
            .alert("Mini Studio", isPresented: $showingAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertText)
            }
            .onAppear {
                loadSavedResults()
                comfyBridge.connect(serverURL, workflowJSON: store.selected?.workflowJSON)
                Task {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    await syncWorkflowFromFrontend()
                    await refreshConnection()
                    await syncResultsFromComfyUI()
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task {
                        await refreshConnection()
                        await syncResultsFromComfyUI()
                    }
                }
            }
            .onChange(of: store.selectedID) { _ in
                disabledReferenceNodeIDs.removeAll()
                referencePreviews.removeAll()
                comfyBridge.connect(serverURL, workflowJSON: store.selected?.workflowJSON)
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    await syncWorkflowFromFrontend()
                }
            }
            .onChange(of: serverURL) { newValue in
                comfyBridge.connect(newValue, workflowJSON: store.selected?.workflowJSON)
            }
        }
        .tint(Color.miniStudioAccent)
        .preferredColorScheme(.dark)
    }

    private var studioHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.miniStudioAccent.opacity(0.30),
                                Color.cyan.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)

                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title3.bold())
                    .foregroundStyle(Color.miniStudioAccent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Workflow Studio")
                    .font(.title3.bold())

                Text(store.selected?.name ?? "Отдельное приложение")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                openComfyUIEditor()
            } label: {
                Image(systemName: "pencil")
                    .font(.subheadline.bold())
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!serverOnline)

            Button {
                Task {
                    await refreshConnection()
                    await syncResultsFromComfyUI()
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(serverOnline ? Color.green : Color.red)
                        .frame(width: 8, height: 8)

                    Text(serverOnline ? "ONLINE" : "OFFLINE")
                        .font(.caption2.bold())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color.black.opacity(0.94))
    }

    private var panelPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MiniStudioPanel.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            panel = item
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.icon)
                            Text(item.rawValue)
                        }
                        .font(.caption.bold())
                        .foregroundStyle(panel == item ? Color.black : Color.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            panel == item ? Color.miniStudioAccent : Color.white.opacity(0.06),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.black.opacity(0.90))
    }

    @ViewBuilder
    private var panelContent: some View {
        switch panel {
        case .generation: generationPanel
        case .references: referencesPanel
        case .controls: controlsPanel
        case .models: modelsPanel
        case .gallery: galleryPanel
        case .workflows: workflowsPanel
        case .settings: settingsPanel
        }
    }

    private var referencesPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                panelTitle("References", subtitle: "Только реальные входы выбранного workflow")

                if let item = store.selected {
                    let materials = store.materials(for: item)
                    let activeCount = materials.filter { !disabledReferenceNodeIDs.contains($0.nodeID) }.count

                    HStack {
                        Label("Активно \(activeCount) / \(materials.count)", systemImage: "checkmark.circle")
                            .font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        if !materials.isEmpty {
                            Button("Enable All") { disabledReferenceNodeIDs.removeAll() }
                                .font(.caption.bold())
                        }
                    }

                    if materials.isEmpty {
                        studioCard(title: "References", icon: "photo.on.rectangle.angled") {
                            Text("В workflow нет поддерживаемых Load Image / Load Video входов.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                            ForEach(materials) { material in
                                MiniStudioReferenceSlot(
                                    material: material,
                                    serverURL: serverURL,
                                    enabled: Binding(
                                        get: { !disabledReferenceNodeIDs.contains(material.nodeID) },
                                        set: { enabled in
                                            if enabled { disabledReferenceNodeIDs.remove(material.nodeID) }
                                            else { disabledReferenceNodeIDs.insert(material.nodeID) }
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

                    Text("Список строится из реальных media-input нод workflow. Bypass относится к конкретной ноде.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else { noWorkflowCard }
            }
            .padding(16).padding(.bottom, 28)
        }
    }

    private var quickPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                panelTitle(
                    "Quick",
                    subtitle: "Основные H3 параметры без открытия ComfyUI"
                )

                if let item = store.selected {
                    quickPromptCard(item)
                    aspectAndDurationCard(item)
                    seedCard(item)
                    turboCard(item)
                    identityCard(item)
                    lastFrameCard(item)
                    previewCard(item)
                    extraQuickCard(item)
                } else {
                    noWorkflowCard
                }
            }
            .padding(16)
            .padding(.bottom, 28)
        }
    }

    private var generationPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                panelTitle(
                    "Generation",
                    subtitle: statusText
                )

                if let item = store.selected {
                    generationPreview
                    quickPromptCard(item)
                    seedCard(item)
                    generationButtons
                } else {
                    noWorkflowCard
                }
            }
            .padding(16)
            .padding(.bottom, 30)
        }
    }

    private var controlsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                panelTitle("Controls", subtitle: "Параметры генерации Mini Studio")
                if let item = store.selected {
                    aspectAndDurationCard(item)
                    turboCard(item)
                    previewCard(item)
                    lastFrameCard(item)
                    identityCard(item)
                    extraQuickCard(item)
                } else {
                    noWorkflowCard
                }
            }
            .padding(16)
            .padding(.bottom, 30)
        }
    }

    private var modelsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                panelTitle("Models & LoRAs", subtitle: "Параметры моделей и LoRA из Mini Studio workflow")
                if let item = store.selected {
                    turboCard(item)
                    identityCard(item)
                    extraQuickCard(item)
                } else {
                    noWorkflowCard
                }
            }
            .padding(16)
            .padding(.bottom, 30)
        }
    }

    private var galleryPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                panelTitle("Gallery", subtitle: "Результаты генерации")
                if results.isEmpty {
                    studioCard(title: "Results", icon: "rectangle.stack") {
                        Text("После генерации фото, видео и аудио появятся здесь.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    recentResults
                }
            }
            .padding(16)
            .padding(.bottom, 30)
        }
    }

    private var workflowsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                panelTitle("Workflows", subtitle: "Сохранённые workflow Mini Studio")
                workflowCard
            }
            .padding(16)
            .padding(.bottom, 30)
        }
    }

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                panelTitle(
                    "Settings",
                    subtitle: "Backend, workflow и параметры нод"
                )

                connectionCard
                workflowCard

                if let item = store.selected {
                    miniStudioSettingsCard(item)
                    nodeSettingsCard(item)
                }
            }
            .padding(16)
            .padding(.bottom, 30)
        }
    }

    private func panelTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func quickPromptCard(_ item: WorkflowItem) -> some View {
        if let prompt = preferredPrompt(for: item) {
            studioCard(title: "Prompt", icon: "text.alignleft") {
                NativeParameterEditor(parameter: prompt, multiline: true, promptActions: true) { parameter, value in
                    applyLiveParameter(parameter, value)
                }
                    .environmentObject(store)
            }
        }
    }

    @ViewBuilder
    private func aspectAndDurationCard(_ item: WorkflowItem) -> some View {
        let width = h3Parameter(
            item,
            keys: ["width"],
            preferredClasses: ["h3identitycontrol", "minimaxh3"]
        )
        let height = h3Parameter(
            item,
            keys: ["height"],
            preferredClasses: ["h3identitycontrol", "minimaxh3"]
        )
        let length = h3Parameter(
            item,
            keys: ["length", "frames", "frames_number"],
            preferredClasses: ["h3identitycontrol", "minimaxh3"]
        )

        if width != nil || height != nil || length != nil {
            studioCard(title: "Format", icon: "rectangle.ratio.16.to.9") {
                if let width, let height {
                    MiniStudioResolutionEditor(width: width, height: height, length: length)
                        .environmentObject(store)
                }

                if let length {
                    Divider().opacity(0.5)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Duration")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            durationButton("3 sec", seconds: 3, parameter: length)
                            durationButton("5 sec", seconds: 5, parameter: length)
                            durationButton("8 sec", seconds: 8, parameter: length)
                        }

                        labeledParameter("Frames", parameter: length)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func seedCard(_ item: WorkflowItem) -> some View {
        if let seed = store.primarySeedParameter(for: item) {
            studioCard(title: "Seed", icon: "dice.fill") {
                NativeSeedEditor(parameter: seed) { parameter, value in
                    applyLiveParameter(parameter, value)
                }
                    .environmentObject(store)
            }
        }
    }

    @ViewBuilder
    private func turboCard(_ item: WorkflowItem) -> some View {
        let parameters = store.studioParameters(
            for: item,
            classContains: ["h3ref2vaturboswitch"]
        )

        if !parameters.isEmpty {
            studioCard(title: "Ref2VA Turbo · LoRA", icon: "bolt.fill") {
                ForEach(parameters) { parameter in
                    quickParameter(parameter)
                }
            }
        }
    }

    @ViewBuilder
    private func identityCard(_ item: WorkflowItem) -> some View {
        let all = store.studioParameters(
            for: item,
            classContains: ["h3identitycontrol"]
        )

        let excludedKeys = Set([
            "prompt",
            "positive_prompt",
            "width",
            "height",
            "length",
            "frames",
            "frames_number"
        ])

        let parameters = all.filter {
            !excludedKeys.contains($0.key.lowercased())
        }

        if !parameters.isEmpty {
            studioCard(title: "H3 Identity Control", icon: "person.crop.rectangle.stack.fill") {
                ForEach(parameters) { parameter in
                    quickParameter(parameter)
                }
            }
        }
    }

    @ViewBuilder
    private func lastFrameCard(_ item: WorkflowItem) -> some View {
        let parameters = store.studioParameters(
            for: item,
            classContains: ["h3savelastframe"]
        )

        if !parameters.isEmpty {
            studioCard(title: "Last Frame", icon: "photo.badge.checkmark") {
                ForEach(parameters) { parameter in
                    quickParameter(parameter)
                }
            }
        }
    }

    @ViewBuilder
    private func previewCard(_ item: WorkflowItem) -> some View {
        let parameters = store.studioParameters(
            for: item,
            classContains: ["h3lightpreviewsampler"]
        )

        if !parameters.isEmpty {
            studioCard(title: "Preview", icon: "eye.fill") {
                ForEach(parameters) { parameter in
                    quickParameter(parameter)
                }
            }
        }
    }

    @ViewBuilder
    private func extraQuickCard(_ item: WorkflowItem) -> some View {
        let pinnedIDs = Set(
            [
                preferredPrompt(for: item)?.id,
                store.primarySeedParameter(for: item)?.id
            ].compactMap { $0 }
        )

        let reservedClasses = [
            "h3identitycontrol",
            "h3ref2vaturboswitch",
            "h3savelastframe",
            "h3lightpreviewsampler"
        ]

        let extra = store.exposedParameters(for: item).filter { parameter in
            !pinnedIDs.contains(parameter.id)
                && !reservedClasses.contains(where: {
                    parameter.classType.lowercased().contains($0)
                })
        }

        if !extra.isEmpty {
            studioCard(title: "Quick Parameters", icon: "slider.horizontal.3") {
                ForEach(extra) { parameter in
                    quickParameter(parameter)
                }
            }
        }
    }

    private var generationPreview: some View {
        studioCard(title: "Preview / Result", icon: "play.rectangle.fill") {
            if let result = results.first {
                Button {
                    selectedResult = result
                } label: {
                    LatestResultPreview(result: result)
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.plain)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.04))
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)

                    VStack(spacing: 10) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.system(size: 42))
                            .foregroundStyle(Color.miniStudioAccent.opacity(0.8))

                        Text("Здесь появится результат")
                            .font(.subheadline.bold())

                        Text("Фото · Видео · Аудио")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if busy {
                VStack(spacing: 8) {
                    ProgressView(value: progress, total: 1)
                        .tint(Color.miniStudioAccent)

                    HStack {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer()

                        Text("\(Int(progress * 100))%")
                            .font(.caption.bold().monospacedDigit())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func generationSummary(_ item: WorkflowItem) -> some View {
        let materials = sortedMaterials(store.materials(for: item))
        let activeRefs = materials.filter {
            !disabledReferenceNodeIDs.contains($0.nodeID)
        }.count

        HStack(spacing: 10) {
            SummaryTile(
                title: "Refs",
                value: "\(activeRefs)/\(materials.count)",
                icon: "photo.on.rectangle.angled"
            )
            SummaryTile(
                title: "Backend",
                value: serverOnline ? "Ready" : "Offline",
                icon: "cpu"
            )
            SummaryTile(
                title: "State",
                value: busy ? "\(Int(progress * 100))%" : "Idle",
                icon: "clock.arrow.circlepath"
            )
        }
    }

    private var generationButtons: some View {
        HStack(spacing: 10) {
            Button {
                Task { await generate() }
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: busy ? "hourglass" : "sparkles")
                    Text(busy ? "GENERATING" : "GENERATE")
                        .font(.headline.bold())
                    Spacer()
                }
                .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.miniStudioAccent)
            .foregroundStyle(.black)
            .disabled(busy || store.selected == nil || !serverOnline)

            if busy {
                Button(role: .destructive) {
                    Task { await stopGeneration() }
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var recentResults: some View {
        studioCard(title: "Results", icon: "photo.stack") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(results.prefix(12)) { result in
                        ResultCompactTile(result: result)
                            .onTapGesture {
                                selectedResult = result
                            }
                    }
                }
            }

            if results.count > 12 {
                Text("Сохранено результатов: \(results.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                clearSavedResults()
            } label: {
                Label("Очистить галерею", systemImage: "trash")
                    .font(.caption.bold())
            }
        }
    }

    private var connectionCard: some View {
        studioCard(title: "ComfyUI Backend", icon: "network") {
            TextField("100.x.x.x:8188", text: $serverURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))

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

                if checkingServer {
                    ProgressView()
                } else {
                    Button("Проверить") {
                        Task { await refreshConnection() }
                    }
                    .font(.caption.bold())
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await syncResultsFromComfyUI() }
                } label: {
                    Label(syncing ? "Результаты…" : "Обновить результаты", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(syncing || !serverOnline)

                Button {
                    openComfyUIEditor()
                } label: {
                    Label("Редактировать", systemImage: "pencil.and.outline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!serverOnline)
            }

            Text("Workflow не синхронизируется автоматически. Кнопка обновления получает только новые результаты генерации из ComfyUI history.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var workflowCard: some View {
        studioCard(title: "Workflow", icon: "point.3.connected.trianglepath.dotted") {
            if store.workflows.isEmpty {
                Text("Workflow ещё не импортирован")
                    .font(.subheadline)
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
                    HStack {
                        Label(
                            selected.apiPromptJSON == nil ? "UI workflow" : "API workflow",
                            systemImage: selected.apiPromptJSON == nil
                                ? "exclamationmark.triangle"
                                : "checkmark.circle.fill"
                        )
                        .font(.caption.bold())
                        .foregroundStyle(selected.apiPromptJSON == nil ? .orange : .green)

                        Spacer()

                        Button(role: .destructive) {
                            store.delete(selected)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }

            Button {
                showingImporter = true
            } label: {
                Label("Импорт Save (API Format) JSON", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Text("После импорта приложение автоматически строит интерфейс Mini Studio из параметров workflow.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func miniStudioSettingsCard(_ item: WorkflowItem) -> some View {
        let sigma = store.studioParameters(
            for: item,
            classContains: ["minimaxh3sigmashift"]
        )
        let createVideo = store.studioParameters(
            for: item,
            classContains: ["createvideo"]
        )
        let sampler = store.studioParameters(
            for: item,
            classContains: ["basicscheduler", "ksamplerselect", "randomnoise"]
        )

        let all = sigma + createVideo + sampler

        if !all.isEmpty {
            studioCard(title: "Mini Studio Settings", icon: "wrench.and.screwdriver.fill") {
                ForEach(uniqueParameters(all)) { parameter in
                    quickParameter(parameter)
                }
            }
        }
    }

    @ViewBuilder
    private func nodeSettingsCard(_ item: WorkflowItem) -> some View {
        let groups = store.nodeGroups(for: item)

        if !groups.isEmpty {
            studioCard(title: "All Node Parameters", icon: "square.stack.3d.up.fill") {
                Text("Можно добавить любой параметр в Quick.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

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
                        VStack(spacing: 10) {
                            ForEach(group.parameters) { parameter in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(parameter.key)
                                            .font(.caption.bold())

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
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }

                                    NativeParameterEditor(
                                        parameter: parameter,
                                        multiline: false
                                    )
                                    .environmentObject(store)
                                }
                                .padding(10)
                                .background(
                                    Color.white.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                                .font(.subheadline.bold())
                            Text(group.classType + " · node " + group.nodeID)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                    }

                    Divider().opacity(0.35)
                }
            }
        }
    }

    private var noWorkflowCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(Color.miniStudioAccent)

            Text("Добавь workflow")
                .font(.title3.bold())

            Text("Импортируй ComfyUI Save (API Format) JSON во вкладке Settings. Приложение само построит функции Mini Studio.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Открыть Settings") {
                panel = .settings
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 18)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

    private func studioCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func quickParameter(_ parameter: WorkflowParameter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(displayName(parameter.key))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                Spacer()

                Text(parameter.nodeTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            NativeParameterEditor(
                parameter: parameter,
                multiline: parameter.kind == .text && parameter.value.count > 80
            )
            .environmentObject(store)
        }
    }

    private func labeledParameter(
        _ label: String,
        parameter: WorkflowParameter
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

            NativeParameterEditor(parameter: parameter, multiline: false)
                .environmentObject(store)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatButton(
        _ label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(label, action: action)
            .font(.caption.bold())
            .frame(maxWidth: .infinity)
            .buttonStyle(.bordered)
    }

    private func setVideoResolution(
        width: WorkflowParameter,
        height: WorkflowParameter,
        shortSide: Int
    ) {
        let currentW = Int(width.value) ?? 832
        let currentH = Int(height.value) ?? 480
        let landscape = currentW >= currentH
        let ratio = max(Double(max(currentW, currentH)) / Double(max(1, min(currentW, currentH))), 1.0)
        let longSide = Int((Double(shortSide) * ratio / 16.0).rounded() * 16.0)
        let alignedShort = max(16, (shortSide / 16) * 16)

        setParameter(width, String(landscape ? longSide : alignedShort))
        setParameter(height, String(landscape ? alignedShort : longSide))
    }

    private func durationButton(
        _ label: String,
        seconds: Int,
        parameter: WorkflowParameter
    ) -> some View {
        Button {
            let frames = seconds * 24 + 4
            setParameter(parameter, String(frames))
        } label: {
            Text(label)
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func preferredPrompt(for item: WorkflowItem) -> WorkflowParameter? {
        if let h3 = store.firstStudioParameter(
            for: item,
            classContains: ["h3identitycontrol"],
            keys: ["prompt", "positive_prompt", "text"]
        ) {
            return h3
        }

        return store.primaryPromptParameter(for: item)
    }

    private func h3Parameter(
        _ item: WorkflowItem,
        keys: [String],
        preferredClasses: [String]
    ) -> WorkflowParameter? {
        if let value = store.firstStudioParameter(
            for: item,
            classContains: preferredClasses,
            keys: keys
        ) {
            return value
        }

        return store.firstStudioParameter(
            for: item,
            keys: keys
        )
    }

    private func setParameter(
        _ parameter: WorkflowParameter,
        _ value: String
    ) {
        store.setParameter(parameter, value: value)
        applyLiveParameter(parameter, value)
    }

    private func applyLiveParameter(_ parameter: WorkflowParameter, _ value: String) {
        Task { @MainActor in
            do {
                try await comfyBridge.applyParameter(
                    nodeID: parameter.nodeID,
                    key: parameter.key,
                    value: value,
                    kind: parameter.kind
                )
            } catch {
                statusText = "Ошибка синхронизации: \(error.localizedDescription)"
            }
        }
    }

    private func uniqueParameters(
        _ parameters: [WorkflowParameter]
    ) -> [WorkflowParameter] {
        var seen = Set<String>()
        return parameters.filter { seen.insert($0.id).inserted }
    }

    private func sortedMaterials(
        _ materials: [WorkflowMaterial]
    ) -> [WorkflowMaterial] {
        materials.sorted { left, right in
            let li = pictureIndex(left.nodeTitle) ?? 10_000
            let ri = pictureIndex(right.nodeTitle) ?? 10_000

            if li == ri {
                return left.nodeTitle.localizedStandardCompare(right.nodeTitle)
                    == .orderedAscending
            }

            return li < ri
        }
    }

    private func materialForPicture(
        _ index: Int,
        in materials: [WorkflowMaterial]
    ) -> WorkflowMaterial? {
        materials.first {
            pictureIndex($0.nodeTitle) == index
        }
    }

    private func pictureIndex(_ title: String) -> Int? {
        let lower = title.lowercased()
        guard let range = lower.range(of: "picture") else { return nil }

        let tail = lower[range.upperBound...]
        guard let start = tail.firstIndex(where: { $0.isNumber }) else {
            return nil
        }

        let digits = tail[start...].prefix { $0.isNumber }
        return Int(digits)
    }

    private func referenceRole(_ index: Int) -> String {
        switch index {
        case 1: return "Лицо · персонаж 1"
        case 2: return "Тело · персонаж 1"
        case 3: return "Лицо · персонаж 2"
        case 4: return "Тело · персонаж 2"
        case 5: return "Первый кадр"
        case 6: return "Деталь 1"
        case 7: return "Деталь 2"
        case 8: return "Деталь 3"
        case 9: return "Деталь 4"
        default: return "Reference"
        }
    }

    private func displayName(_ key: String) -> String {
        key
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .capitalized
    }

    private var cardBackground: Color {
        Color.white.opacity(0.055)
    }

    private var studioBackground: some View {
        LinearGradient(
            colors: [
                Color.black,
                Color(red: 0.018, green: 0.05, blue: 0.045),
                Color.black
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
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

        checkingServer = true
        statusText = "Проверяю ComfyUI…"

        let result = await ComfyClient.check(base: serverURL)
        serverOnline = result.online
        statusText = result.message

        if let normalized = result.normalizedURL {
            serverURL = normalized
        }

        checkingServer = false
    }

    @MainActor
    private func syncResultsFromComfyUI() async {
        guard serverOnline, !serverURL.isEmpty, !syncing else { return }
        syncing = true
        defer { syncing = false }

        do {
            let history = try await ComfyClient.recentHistory(base: serverURL, maxItems: 30)
            let knownPaths = Set(results.map { $0.url.lastPathComponent })
            var newFiles: [ComfyOutputFile] = []

            for entry in history {
                for file in entry.files where !knownPaths.contains(file.filename) {
                    if !newFiles.contains(file) {
                        newFiles.append(file)
                    }
                }
            }

            if !newFiles.isEmpty {
                let synced = try await saveResults(newFiles)
                let existing = Set(results.map { $0.url.path })
                results.insert(contentsOf: synced.filter { !existing.contains($0.url.path) }, at: 0)
            }

            statusText = newFiles.isEmpty
                ? "Результаты синхронизированы"
                : "Получено новых результатов: \(newFiles.count)"
        } catch {
            statusText = "ComfyUI online · результаты недоступны"
        }
    }

    @MainActor
    private func loadReferencePreviews() async {
        guard let item = store.selected else { return }
        let materials = store.materials(for: item)

        for material in materials where material.kind == .image {
            guard pictureIndex(material.nodeTitle) != nil,
                  !material.currentValue.isEmpty,
                  referencePreviews[material.id] == nil else { continue }

            if let data = try? await ComfyClient.inputData(
                base: serverURL,
                remoteName: material.currentValue
            ), let image = UIImage(data: data) {
                referencePreviews[material.id] = image
            }
        }
    }

    private func openComfyUIEditor() {
        guard ComfyClient.editorURL(base: serverURL) != nil else {
            showMessage("Неверный адрес ComfyUI")
            return
        }
        showingComfyEditor = true
    }

    @MainActor
    private func generate() async {
        guard serverOnline else {
            showMessage("ComfyUI offline. Проверь адрес во вкладке Settings.")
            panel = .settings
            return
        }
        guard let currentItem = store.selected else { return }

        busy = true
        progress = 0.03
        statusText = "Синхронизирую workflow с ComfyUI…"

        do {
            // UI workflows with subgraphs must be flattened by the real ComfyUI frontend.
            // API-format workflows keep the direct /prompt path as a compatibility fallback.
            if currentItem.workflowJSON != nil {
                comfyBridge.connect(serverURL, workflowJSON: currentItem.workflowJSON)
                let state = store.frontendState(for: currentItem, disabledNodeIDs: disabledReferenceNodeIDs)
                try await comfyBridge.apply(state)
                statusText = "Отправляю через ComfyUI…"
                progress = 0.08
                let livePrompt = preferredPrompt(for: currentItem)?.value
                let liveSeed = store.primarySeedParameter(for: currentItem)?.value
                try await comfyBridge.queue(promptText: livePrompt, seedValue: liveSeed)
                statusText = "Команда отправлена в ComfyUI"
                // The frontend owns the exact prompt id; result sync reconciles history.
                for step in 0..<7200 where busy {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if step % 2 == 0 {
                        let before = results.count
                        await syncResultsFromComfyUI()
                        if results.count > before {
                            progress = 1
                            statusText = "Готово · новый результат"
                            break
                        }
                    }
                    progress = min(0.92, progress + 0.003)
                }
            } else {
                let livePrompt = preferredPrompt(for: currentItem)?.value
                let liveSeed = store.primarySeedParameter(for: currentItem)?.value
                guard let prompt = store.preparedPrompt(disabledNodeIDs: disabledReferenceNodeIDs, promptText: livePrompt, seedValue: liveSeed) else {
                    throw NSError(domain: "MiniStudio", code: 20, userInfo: [NSLocalizedDescriptionKey: "Нет исполняемого workflow"])
                }
                let promptID = try await ComfyClient.queue(base: serverURL, prompt: prompt)
                statusText = "В очереди · \(promptID.prefix(8))"
                progress = 0.08
                var finished = false
                var checks = 0
                while busy && !finished && checks < 7200 {
                    try await Task.sleep(nanoseconds: 1_000_000_000); checks += 1
                    finished = try await ComfyClient.generationFinished(base: serverURL, promptID: promptID)
                    if finished {
                        let files = try await ComfyClient.resultFiles(base: serverURL, promptID: promptID)
                        let newResults = try await saveResults(files)
                        results.insert(contentsOf: newResults, at: 0)
                        progress = 1
                        statusText = "Готово · \(newResults.count) результат(а)"
                    } else { progress = min(0.92, progress + 0.003) }
                }
            }
        } catch {
            statusText = "Ошибка генерации"
            showMessage(error.localizedDescription)
        }
        busy = false
        if progress >= 1 { try? await Task.sleep(nanoseconds: 300_000_000) }
        progress = 0
    }

    @MainActor
    private func syncWorkflowFromFrontend() async {
        do {
            guard let snapshot = try await comfyBridge.snapshot() else { return }
            store.updateFromEditor(workflow: snapshot.workflow, output: snapshot.output)
        } catch {
            // Keep the last usable local workflow if the frontend is still loading.
        }
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
        progress = 0
    }

    private func saveResults(
        _ files: [ComfyOutputFile]
    ) async throws -> [LocalStudioResult] {
        guard !files.isEmpty else { return [] }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: resultsDirectory,
            withIntermediateDirectories: true
        )

        var saved: [LocalStudioResult] = []

        for file in files {
            let data = try await ComfyClient.resultData(
                base: serverURL,
                file: file
            )

            let safeName = (file.filename as NSString).lastPathComponent
            var destination = resultsDirectory
                .appendingPathComponent(safeName)

            if fileManager.fileExists(atPath: destination.path) {
                destination = resultsDirectory.appendingPathComponent(
                    String(UUID().uuidString.prefix(8)) + "-" + safeName
                )
            }

            try data.write(to: destination, options: [.atomic])

            saved.append(
                LocalStudioResult(
                    url: destination,
                    kind: file.kind
                )
            )
        }

        return saved
    }

    private var resultsDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                "Mini Studio Results",
                isDirectory: true
            )
    }

    private func loadSavedResults() {
        let fileManager = FileManager.default

        try? fileManager.createDirectory(
            at: resultsDirectory,
            withIntermediateDirectories: true
        )

        let urls = (
            try? fileManager.contentsOfDirectory(
                at: resultsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        ) ?? []

        results = urls
            .filter { !$0.hasDirectoryPath }
            .sorted {
                let left = (
                    try? $0.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate
                ) ?? .distantPast

                let right = (
                    try? $1.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate
                ) ?? .distantPast

                return left > right
            }
            .map {
                LocalStudioResult(
                    url: $0,
                    kind: resultKind(for: $0)
                )
            }
    }

    private func clearSavedResults() {
        let fileManager = FileManager.default

        for result in results {
            try? fileManager.removeItem(at: result.url)
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

    private func importWorkflow(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)

            try store.importJSON(
                data: data,
                suggestedName: url
                    .deletingPathExtension()
                    .lastPathComponent
            )

            if store.selected?.apiPromptJSON == nil {
                showMessage(
                    "JSON импортирован, но это UI workflow. Для Generate нужен Save (API Format) JSON."
                )
            } else {
                showMessage("API workflow импортирован. Mini Studio интерфейс построен автоматически.")
            }
        } catch {
            showMessage(error.localizedDescription)
        }
    }
}

private struct WorkflowJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct EmbeddedComfyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var bridge: ComfyFrontendBridge
    let onSync: () async -> Void
    @State private var exportDocument: WorkflowJSONDocument?
    @State private var exportName = "workflow"
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Label("Назад", systemImage: "chevron.left") }
                Spacer()
                Text("Workflow").font(.headline)
                Spacer()
                Button {
                    Task {
                        do {
                            let data = try await bridge.exportWorkflowData()
                            exportName = "workflow-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                            exportDocument = WorkflowJSONDocument(data: data)
                        } catch {
                            exportError = error.localizedDescription
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }

                Button { bridge.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(.horizontal, 14).frame(height: 52).background(Color.black)
            ComfyBridgeWebView(bridge: bridge).ignoresSafeArea(edges: .bottom)
        }
        .onAppear { Task { try? await bridge.ensureFlatWorkflow() } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { break }
                await onSync()
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }
            ),
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportName
        ) { _ in
            exportDocument = nil
        }
        .alert("Экспорт workflow", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .preferredColorScheme(.dark)
    }
}

private struct ComfyBridgeWebView: UIViewRepresentable {
    @ObservedObject var bridge: ComfyFrontendBridge
    func makeUIView(context: Context) -> WKWebView { bridge.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
private final class ComfyFrontendBridge: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var ready = false
    private var address = ""
    private var workflowJSON: Data?
    private var pendingLoad = false
    private var workflowLoaded = false

    lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.isOpaque = false
        view.backgroundColor = .black
        return view
    }()

    func connect(_ address: String, workflowJSON: Data?) {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let sameAddress = self.address == normalized && webView.url != nil
        let workflowChanged = self.workflowJSON != workflowJSON
        self.workflowJSON = workflowJSON

        if sameAddress {
            // Do not reload the graph just because Generate/sync called connect again.
            // Reloading here used to overwrite edits made in the embedded ComfyUI editor.
            if workflowChanged {
                workflowLoaded = false
                Task { try? await loadWorkflowIfNeeded(force: true) }
            }
            return
        }

        self.address = normalized
        ready = false
        workflowLoaded = false
        guard let url = ComfyClient.editorURL(base: normalized) else { return }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func reload() { ready = false; webView.reload() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { try? await loadWorkflowIfNeeded(force: true) }
    }

    private func js(_ source: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
    }

    private func loadWorkflowIfNeeded(force: Bool) async throws {
        guard let workflowJSON else { ready = true; workflowLoaded = true; return }
        if pendingLoad { return }
        if workflowLoaded && !force { return }
        pendingLoad = true; defer { pendingLoad = false }
        let encoded = workflowJSON.base64EncodedString()
        let result = try await js("""
        const { app } = await import(new URL('scripts/app.js', document.baseURI).href);
        const raw = atob('\(encoded)');
        const workflow = JSON.parse(new TextDecoder().decode(Uint8Array.from(raw, c => c.charCodeAt(0))));
        await app.loadGraphData(workflow, true, true);
        const root = app.rootGraph || app.graph;
        let changed = true;
        while (changed) {
          changed = false;
          for (const node of Array.from(root?.nodes || root?._nodes || [])) {
            if (!node?.subgraph) continue;
            const ok = root.unpackSubgraph(node, { skipMissingNodes: false });
            if (!ok) throw new Error('Не удалось распаковать subgraph: ' + (node.title || node.id));
            changed = true;
            break;
          }
        }
        app.canvas?.setGraph?.(root);
        app.canvas?.setDirty?.(true, true);
        return 'loaded';
        """)
        ready = (result as? String) == "loaded"
        workflowLoaded = ready
    }

    func ensureFlatWorkflow() async throws {
        try await loadWorkflowIfNeeded(force: false)
        _ = try await js("""
        const { app } = await import(new URL('scripts/app.js', document.baseURI).href);
        const root = app.rootGraph || app.graph;
        let changed = true;
        while (changed) {
          changed = false;
          const nodes = Array.from(root?.nodes || root?._nodes || []);
          for (const node of nodes) {
            if (!node?.subgraph) continue;
            const ok = root.unpackSubgraph(node, { skipMissingNodes: false });
            if (!ok) throw new Error('Не удалось распаковать subgraph: ' + (node.title || node.id));
            changed = true;
            break;
          }
        }
        app.canvas?.setGraph?.(root);
        app.canvas?.setDirty?.(true, true);
        return 'flat';
        """)
    }

    struct Snapshot {
        let workflow: Any
        let output: Any
    }

    func snapshot() async throws -> Snapshot? {
        try await ensureFlatWorkflow()
        guard let result = try await js("""
        const { app } = await import(new URL('scripts/app.js', document.baseURI).href);
        const workflow = app.graph.serialize();
        const prompt = await app.graphToPrompt();
        return JSON.stringify({ workflow, output: prompt.output });
        """) as? String,
        let data = result.data(using: .utf8),
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let workflow = object["workflow"],
        let output = object["output"] else { return nil }
        return Snapshot(workflow: workflow, output: output)
    }

    func exportWorkflowData() async throws -> Data {
        try await ensureFlatWorkflow()
        guard let result = try await js("""
        const { app } = await import(new URL('scripts/app.js', document.baseURI).href);
        return JSON.stringify(app.graph.serialize(), null, 2);
        """) as? String,
        let data = result.data(using: .utf8) else {
            throw NSError(domain: "WorkflowStudio", code: 41, userInfo: [NSLocalizedDescriptionKey: "Не удалось получить текущий workflow из редактора"])
        }
        return data
    }

    func applyParameter(nodeID: String, key: String, value: String, kind: WorkflowParameter.ValueKind) async throws {
        try await loadWorkflowIfNeeded(force: false)
        let payload: [String: Any] = ["nodeID": nodeID, "key": key, "value": value]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
        let result = try await js("""
        const { app } = await import(new URL('scripts/app.js', document.baseURI).href);
        const raw = atob('(encoded)');
        const p = JSON.parse(new TextDecoder().decode(Uint8Array.from(raw, c => c.charCodeAt(0))));
        const root = app.rootGraph || app.graph;
        const graphs = [root, ...Array.from(root?.subgraphs?.values?.() || [])];
        let node = null;
        for (const graph of graphs) {
          node = Array.from(graph?._nodes || graph?.nodes || []).find(n => String(n.id) === String(p.nodeID));
          if (node) break;
        }
        if (!node) throw new Error('Node ' + p.nodeID + ' не найдена в live workflow');
        const widgets = Array.from(node.widgets || []);
        let widget = widgets.find(w => String(w.name || '').toLowerCase() === String(p.key).toLowerCase());
        if (!widget) {
          const aliases = { positive_prompt:['prompt','text'], prompt:['positive_prompt','text'], noise_seed:['seed'], seed:['noise_seed'] };
          const names = aliases[String(p.key).toLowerCase()] || [];
          widget = widgets.find(w => names.includes(String(w.name || '').toLowerCase()));
        }
        if (!widget) throw new Error('Параметр ' + p.key + ' не найден в node ' + p.nodeID);
        let v = p.value;
        if (typeof widget.value === 'number') v = Number(v);
        else if (typeof widget.value === 'boolean') v = ['true','1','yes','on'].includes(String(v).toLowerCase());
        widget.value = v;
        widget.callback?.(widget.value, app.canvas, node, app.canvas?.graph_mouse, {});
        node.onWidgetChanged?.(widget.name, widget.value, widget.value, widget);
        node.graph?.setDirtyCanvas?.(true, true);
        app.canvas?.setDirty?.(true, true);
        return 'applied';
        """)
        if (result as? String) != "applied" {
            throw NSError(domain:"WorkflowStudio",code:33,userInfo:[NSLocalizedDescriptionKey:"Live параметр не применён"])
        }
    }

    func apply(_ state: [String: Any]) async throws {
        try await loadWorkflowIfNeeded(force: false)
        let data = try JSONSerialization.data(withJSONObject: state)
        let encoded = data.base64EncodedString()
        let result = try await js("""
        const { app } = await import(new URL('scripts/app.js', document.baseURI).href);
        const raw = atob('\(encoded)');
        const state = JSON.parse(new TextDecoder().decode(Uint8Array.from(raw, c => c.charCodeAt(0))));
        const root = app.rootGraph || app.graph;
        const allGraphs = [root, ...Array.from(root?.subgraphs?.values?.() || [])];
        for (const graph of allGraphs) {
          for (const node of Array.from(graph?._nodes || graph?.nodes || [])) {
            const id = String(node.id);
            const patch = state.nodes?.[id];
            if (!patch) continue;
            const widgets = node.widgets || [];
            for (let wi = 0; wi < widgets.length; wi++) {
              const w = widgets[wi];
              const values = patch.values || {};
              const hasNamed = Object.prototype.hasOwnProperty.call(values, w.name);
              const indexed = '__index_' + wi;
              const hasIndexed = Object.prototype.hasOwnProperty.call(values, indexed);
              if (hasNamed || hasIndexed) {
                w.value = hasNamed ? values[w.name] : values[indexed];
                w.callback?.(w.value, app.canvas, node, app.canvas?.graph_mouse, {});
              }
            }
            if (patch.mode !== undefined) node.mode = patch.mode;
          }
        }
        app.canvas?.setDirty?.(true, true);
        return 'applied';
        """)
        if (result as? String) != "applied" { throw NSError(domain:"MiniStudio",code:31,userInfo:[NSLocalizedDescriptionKey:"Не удалось применить настройки в ComfyUI"]) }
    }

    func queue(promptText: String?, seedValue: String?) async throws {
        try await ensureFlatWorkflow()
        let payload: [String: Any] = [
            "prompt": promptText ?? NSNull(),
            "seed": seedValue ?? NSNull()
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()

        do {
            let result = try await js("""
            const { app } = await import(new URL('scripts/app.js', document.baseURI).href);
            const raw = atob('(encoded)');
            const payload = JSON.parse(new TextDecoder().decode(Uint8Array.from(raw, c => c.charCodeAt(0))));
            const nodes = Array.from((app.rootGraph || app.graph)?._nodes || (app.rootGraph || app.graph)?.nodes || []);

            const setWidget = (node, names, value) => {
              if (value === null || value === undefined) return false;
              const widgets = Array.from(node?.widgets || []);
              const widget = widgets.find(w => names.includes(String(w.name || '').toLowerCase()));
              if (!widget) return false;
              widget.value = value;
              widget.callback?.(widget.value, app.canvas, node, app.canvas?.graph_mouse, {});
              return true;
            };

            let promptApplied = payload.prompt == null;
            if (payload.prompt != null) {
              const preferred = nodes.filter(n => String(n.type || n.comfyClass || '').toLowerCase().includes('h3identitycontrol'));
              for (const node of [...preferred, ...nodes]) {
                if (setWidget(node, ['prompt','positive_prompt','text'], payload.prompt)) {
                  promptApplied = true;
                  break;
                }
              }
            }

            if (!promptApplied) {
              throw new Error('Не найден реальный Prompt widget в workflow');
            }

            if (payload.seed != null) {
              const seed = Number(payload.seed);
              if (Number.isFinite(seed)) {
                const preferred = nodes.filter(n => String(n.type || n.comfyClass || '').toLowerCase().includes('randomnoise'));
                for (const node of [...preferred, ...nodes]) {
                  if (setWidget(node, ['noise_seed','seed'], seed)) break;
                }
              }
            }

            app.canvas?.setDirty?.(true, true);
            const prompt = await app.graphToPrompt();
            if (!prompt?.output || Object.keys(prompt.output).length === 0) {
              throw new Error('ComfyUI создал пустой API prompt');
            }

            const response = await fetch(new URL('prompt', document.baseURI), {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ prompt: prompt.output, client_id: app.api?.clientId })
            });
            const body = await response.text();
            if (!response.ok) throw new Error('ComfyUI /prompt ' + response.status + ': ' + body);
            let parsed = {};
            try { parsed = JSON.parse(body); } catch {}
            if (parsed.error) throw new Error(typeof parsed.error === 'string' ? parsed.error : JSON.stringify(parsed.error));
            return JSON.stringify({ ok: true, prompt_id: parsed.prompt_id || null });
            """)

            guard let text = result as? String,
                  let resultData = text.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: resultData) as? [String: Any],
                  object["ok"] as? Bool == true else {
                throw NSError(domain: "WorkflowStudio", code: 32, userInfo: [NSLocalizedDescriptionKey: "ComfyUI не подтвердил запуск"])
            }
        } catch {
            throw NSError(
                domain: "WorkflowStudio",
                code: 32,
                userInfo: [NSLocalizedDescriptionKey: "Ошибка ComfyUI: \(error.localizedDescription)"]
            )
        }
    }
}

private struct MiniStudioReferenceSlot: View {
    @EnvironmentObject private var store: WorkflowStore

    let material: WorkflowMaterial
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
                matching: material.kind == .video ? .videos : .images
            ) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.055))
                        .aspectRatio(1, contentMode: .fit)

                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFill()
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        VStack(spacing: 8) {
                            Image(
                                systemName: material == nil
                                    ? "exclamationmark.triangle"
                                    : "photo.badge.plus"
                            )
                            .font(.title2)

                            Text(
                                material == nil
                                    ? "Нет input"
                                    : "Добавить"
                            )
                            .font(.caption.bold())
                        }
                        .foregroundStyle(
                            material == nil
                                ? Color.secondary
                                : Color.miniStudioAccent
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    Text(material.nodeTitle)
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(7)

                    if !enabled {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black.opacity(0.64))

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
                            .fill(Color.black.opacity(0.58))

                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!enabled || uploading)
            .onChange(of: selection) { item in
                guard let item else { return }
                Task { await importItem(item) }
            }
            .task(id: material.currentValue) {
                await loadExistingPreview()
            }

            Text(material.kind == .video ? "Load Video" : "Load Image")
                .font(.caption.bold())
                .lineLimit(2)

            HStack {
                Text(
                    enabled ? "Active" : "Bypass"
                )
                .font(.caption2)
                .foregroundStyle(
                    enabled ? Color.miniStudioAccent : Color.secondary
                )

                Spacer()

                if true {
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .scaleEffect(0.82)
                }
            }
        }
        .padding(10)
        .background(
            Color.white.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 19)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 19)
                .stroke(
                    enabled
                        ? Color.miniStudioAccent.opacity(0.18)
                        : Color.white.opacity(0.05),
                    lineWidth: 1
                )
        )
    }

    @MainActor
    private func loadExistingPreview() async {
        guard previewImage == nil,
              material.kind == .image,
              !material.currentValue.isEmpty,
              !serverURL.isEmpty else { return }

        if let data = try? await ComfyClient.inputData(
            base: serverURL,
            remoteName: material.currentValue
        ), let image = UIImage(data: data) {
            previewImage = image
        }
    }

    @MainActor
    private func importItem(_ item: PhotosPickerItem) async {
        guard !serverURL.isEmpty else {
            onStatus("Сначала укажи адрес ComfyUI в Settings.")
            return
        }

        uploading = true
        defer { uploading = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ComfyClientError.network(
                    "Не удалось прочитать выбранный файл"
                )
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

            let filename =
                "mini_studio_picture_\(index)_" +
                UUID().uuidString +
                "." +
                ext

            if material.kind == .image {
                previewImage = UIImage(data: data)
            }

            let remote = try await ComfyClient.uploadInput(
                base: serverURL,
                data: data,
                fileName: filename,
                mimeType: mime
            )

            store.setMaterial(
                material,
                remoteName: remote
            )
        } catch {
            onStatus(error.localizedDescription)
        }
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(Color.miniStudioAccent)

            Text(value)
                .font(.subheadline.bold())
                .lineLimit(1)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color.white.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 15)
        )
    }
}

private struct MiniStudioResolutionEditor: View {
    @EnvironmentObject private var store: WorkflowStore
    let width: WorkflowParameter
    let height: WorkflowParameter
    let length: WorkflowParameter?

    @State private var ratio = "16:9"
    @State private var megapixels = "0.400"

    private let ratios = ["16:9","9:16","1:1","4:3","3:4","3:2","2:3","21:9"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aspect ratio")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(ratios, id: \.self) { item in
                        Button(item) {
                            ratio = item
                            apply()
                        }
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                        .tint(ratio == item ? Color.miniStudioAccent : Color.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Megapixels")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField("0.400", text: $megapixels)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { apply() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Pixels")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text("\(width.value) × \(height.value)")
                        .font(.subheadline.monospacedDigit().bold())
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                }
            }

            let frames = length?.value ?? "—"
            Text("\(width.value) × \(height.value) · \(currentMP) MP · \(frames) frames / 24 fps · H3 frame grid")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { syncFromParameters() }
        .onChange(of: width.value) { _ in syncFromParameters() }
        .onChange(of: height.value) { _ in syncFromParameters() }
    }

    private var currentMP: String {
        let w = Double(width.value) ?? 0
        let h = Double(height.value) ?? 0
        return String(format: "%.3f", w * h / 1_000_000)
    }

    private func syncFromParameters() {
        let w = Double(width.value) ?? 832
        let h = Double(height.value) ?? 480
        megapixels = String(format: "%.3f", w * h / 1_000_000)
        ratio = ratios.min { a, b in
            ratioDistance(a, w / max(h, 1)) < ratioDistance(b, w / max(h, 1))
        } ?? "16:9"
    }

    private func ratioDistance(_ text: String, _ target: Double) -> Double {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return 999 }
        return abs(parts[0] / parts[1] - target)
    }

    private func apply() {
        let mp = min(max(Double(megapixels.replacingOccurrences(of: ",", with: ".")) ?? 0.4, 0.1), 8.0)
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        let a = parts[0], b = parts[1]
        let w = max(32, Int((sqrt(mp * 1_000_000 * a / b) / 32).rounded()) * 32)
        let h = max(32, Int((sqrt(mp * 1_000_000 * b / a) / 32).rounded()) * 32)
        store.setParameter(width, value: String(w))
        store.setParameter(height, value: String(h))
        megapixels = String(format: "%.3f", Double(w * h) / 1_000_000)
    }
}

private struct NativeParameterEditor: View {
    @EnvironmentObject private var store: WorkflowStore

    let parameter: WorkflowParameter
    let multiline: Bool
    let promptActions: Bool
    let onLiveChange: ((WorkflowParameter, String) -> Void)?

    @State private var value: String
    @FocusState private var textFocused: Bool

    init(
        parameter: WorkflowParameter,
        multiline: Bool,
        promptActions: Bool = false,
        onLiveChange: ((WorkflowParameter, String) -> Void)? = nil
    ) {
        self.parameter = parameter
        self.multiline = multiline
        self.promptActions = promptActions
        self.onLiveChange = onLiveChange
        _value = State(initialValue: parameter.value)
    }

    var body: some View {
        Group {
            if parameter.kind == .boolean {
                Toggle(
                    "",
                    isOn: Binding(
                        get: {
                            (value as NSString).boolValue
                        },
                        set: { newValue in
                            value = newValue ? "true" : "false"
                            store.setParameter(
                                parameter,
                                value: value
                            )
                            onLiveChange?(parameter, value)
                        }
                    )
                )
                .labelsHidden()
            } else if multiline && parameter.kind == .text {
                VStack(spacing: 8) {
                    TextEditor(text: $value)
                        .focused($textFocused)
                        .frame(minHeight: 124)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(
                            Color.white.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .onChange(of: value) { newValue in
                            store.setParameter(parameter, value: newValue)
                            onLiveChange?(parameter, newValue)
                        }

                    if promptActions {
                        HStack(spacing: 10) {
                            Button("Выделить всё") {
                                textFocused = true
                                DispatchQueue.main.async {
                                    UIApplication.shared.sendAction(
                                        #selector(UIResponder.selectAll(_:)),
                                        to: nil, from: nil, for: nil
                                    )
                                }
                            }
                            .buttonStyle(.bordered)

                            Button("Вставить") {
                                if let pasted = UIPasteboard.general.string {
                                    value = pasted
                                    store.setParameter(parameter, value: pasted)
                                    onLiveChange?(parameter, pasted)
                                    textFocused = true
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Spacer()
                        }
                    }
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
                    .background(
                        Color.white.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .onChange(of: value) { newValue in
                        store.setParameter(
                            parameter,
                            value: newValue
                        )
                        onLiveChange?(parameter, newValue)
                    }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") {
                    textFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
    let onLiveChange: ((WorkflowParameter, String) -> Void)?
    @State private var value: String
    @FocusState private var seedFocused: Bool

    init(parameter: WorkflowParameter, onLiveChange: ((WorkflowParameter, String) -> Void)? = nil) {
        self.parameter = parameter
        self.onLiveChange = onLiveChange
        _value = State(initialValue: parameter.value)
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField("Seed", text: $value)
                .focused($seedFocused)
                .keyboardType(.numbersAndPunctuation)
                .padding(12)
                .background(
                    Color.white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .onChange(of: value) { newValue in
                    store.setParameter(
                        parameter,
                        value: newValue
                    )
                }

            Button {
                value = String(
                    Int64.random(in: 0...Int64.max)
                )

                store.setParameter(
                    parameter,
                    value: value
                )
            } label: {
                Image(systemName: "dice.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") {
                    seedFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .onChange(of: parameter.value) { newValue in
            if value != newValue { value = newValue }
        }
    }
}

private struct LatestResultPreview: View {
    let result: LocalStudioResult

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.04))
                .aspectRatio(16.0 / 10.0, contentMode: .fit)

            switch result.kind {
            case .image:
                if let image = UIImage(
                    contentsOfFile: result.url.path
                ) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }

            case .video:
                VStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.miniStudioAccent)

                    Text(result.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

            case .audio:
                VStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.miniStudioAccent)

                    Text(result.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

            case .file:
                VStack(spacing: 10) {
                    Image(systemName: "doc.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.miniStudioAccent)

                    Text(result.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct ResultCompactTile: View {
    let result: LocalStudioResult

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
                .frame(width: 112, height: 112)

            if result.kind == .image,
               let image = UIImage(
                contentsOfFile: result.url.path
               ) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 112, height: 112)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 14)
                    )
            } else {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(Color.miniStudioAccent)
            }

            if result.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                    .shadow(radius: 5)
            }
        }
        .contentShape(
            RoundedRectangle(cornerRadius: 14)
        )
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

    @State private var audioPlayer: AVPlayer?
    @State private var audioPlaying = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 0)

                switch result.kind {
                case .image:
                    if let image = UIImage(
                        contentsOfFile: result.url.path
                    ) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(
                                RoundedRectangle(cornerRadius: 18)
                            )
                            .padding(.horizontal)
                    }

                case .video:
                    VideoPlayer(
                        player: AVPlayer(url: result.url)
                    )
                    .aspectRatio(
                        16.0 / 9.0,
                        contentMode: .fit
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: 18)
                    )
                    .padding(.horizontal)

                case .audio:
                    VStack(spacing: 18) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 86))
                            .foregroundStyle(Color.miniStudioAccent)

                        Button {
                            toggleAudio()
                        } label: {
                            Label(
                                audioPlaying ? "Pause" : "Play Audio",
                                systemImage: audioPlaying
                                    ? "pause.fill"
                                    : "play.fill"
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.miniStudioAccent)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 28)
                    }

                case .file:
                    VStack(spacing: 16) {
                        Image(systemName: "doc.circle.fill")
                            .font(.system(size: 86))
                            .foregroundStyle(Color.miniStudioAccent)

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
                    Label(
                        "Поделиться / сохранить",
                        systemImage: "square.and.arrow.up"
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.miniStudioAccent)
                .foregroundStyle(.black)
                .padding(.horizontal)

                Spacer(minLength: 0)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("Закрыть") {
                        audioPlayer?.pause()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func toggleAudio() {
        if audioPlayer == nil {
            audioPlayer = AVPlayer(url: result.url)
        }

        if audioPlaying {
            audioPlayer?.pause()
        } else {
            audioPlayer?.play()
        }

        audioPlaying.toggle()
    }
}
