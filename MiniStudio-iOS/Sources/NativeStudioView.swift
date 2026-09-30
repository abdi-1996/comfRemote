import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AVKit

private enum MiniStudioPanel: String, CaseIterable, Identifiable {
    case references = "References"
    case quick = "Quick"
    case generation = "Generation"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .references: return "photo.on.rectangle.angled"
        case .quick: return "slider.horizontal.3"
        case .generation: return "sparkles"
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
                        .tint(.mint)
                        .frame(height: 2)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedResult) { result in
                ResultDetailView(result: result)
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
                Task {
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
            }
        }
        .tint(.mint)
        .preferredColorScheme(.dark)
    }

    private var studioHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.mint.opacity(0.30),
                                Color.cyan.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)

                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.mint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Mini Studio")
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
                            panel == item ? Color.mint : Color.white.opacity(0.06),
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
        case .references:
            referencesPanel
        case .quick:
            quickPanel
        case .generation:
            generationPanel
        case .settings:
            settingsPanel
        }
    }

    private var referencesPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                panelTitle(
                    "References",
                    subtitle: "Picture1–9 работают так же, как в Mini Studio node"
                )

                if let item = store.selected {
                    let materials = sortedMaterials(store.materials(for: item))
                    let activeCount = materials.filter {
                        !disabledReferenceNodeIDs.contains($0.nodeID)
                    }.count

                    HStack {
                        Label(
                            "Активно \(activeCount) / \(materials.count)",
                            systemImage: "checkmark.circle"
                        )
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                        Spacer()

                        Button("Enable All") {
                            disabledReferenceNodeIDs.removeAll()
                        }
                        .font(.caption.bold())
                    }
                    .padding(.horizontal, 2)

                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 145), spacing: 12)
                        ],
                        spacing: 12
                    ) {
                        ForEach(1...9, id: \.self) { index in
                            let material = materialForPicture(index, in: materials)

                            MiniStudioReferenceSlot(
                                index: index,
                                role: referenceRole(index),
                                material: material,
                                serverURL: serverURL,
                                enabled: Binding(
                                    get: {
                                        guard let material else { return false }
                                        return !disabledReferenceNodeIDs.contains(material.nodeID)
                                    },
                                    set: { enabled in
                                        guard let material else { return }
                                        if enabled {
                                            disabledReferenceNodeIDs.remove(material.nodeID)
                                        } else {
                                            disabledReferenceNodeIDs.insert(material.nodeID)
                                        }
                                    }
                                ),
                                previewImage: Binding(
                                    get: {
                                        guard let material else { return nil }
                                        return referencePreviews[material.id]
                                    },
                                    set: { image in
                                        guard let material else { return }
                                        referencePreviews[material.id] = image
                                    }
                                ),
                                onStatus: showMessage
                            )
                            .environmentObject(store)
                        }
                    }

                    Text("Bypass удаляет соответствующий reference-node из API prompt перед отправкой в ComfyUI и отсоединяет его входы.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                } else {
                    noWorkflowCard
                }
            }
            .padding(16)
            .padding(.bottom, 28)
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
                    generationSummary(item)
                    generationButtons

                    if !results.isEmpty {
                        recentResults
                    }
                } else {
                    noWorkflowCard
                }
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
                NativeParameterEditor(parameter: prompt, multiline: true, promptActions: true)
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Aspect ratio")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            formatButton("16:9") {
                                setParameter(width, "832")
                                setParameter(height, "480")
                            }
                            formatButton("9:16") {
                                setParameter(width, "480")
                                setParameter(height, "832")
                            }
                            formatButton("1:1") {
                                setParameter(width, "768")
                                setParameter(height, "768")
                            }
                        }

                        HStack(spacing: 10) {
                            labeledParameter("Width px", parameter: width)
                            labeledParameter("Height px", parameter: height)
                        }

                        Text("Video resolution · pixels")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        HStack(spacing: 8) {
                            formatButton("480p") {
                                setVideoResolution(width: width, height: height, shortSide: 480)
                            }
                            formatButton("720p") {
                                setVideoResolution(width: width, height: height, shortSide: 720)
                            }
                            formatButton("1080p") {
                                setVideoResolution(width: width, height: height, shortSide: 1080)
                            }
                        }
                    }
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
                NativeSeedEditor(parameter: seed)
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
                }
                .buttonStyle(.plain)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.04))
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)

                    VStack(spacing: 10) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.system(size: 42))
                            .foregroundStyle(.mint.opacity(0.8))

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
                        .tint(.mint)

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
            .tint(.mint)
            .foregroundStyle(.black)
            .disabled(busy || store.selected?.apiPromptJSON == nil || !serverOnline)

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
                .foregroundStyle(.mint)

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
        guard let url = ComfyClient.editorURL(base: serverURL) else {
            showMessage("Неверный адрес ComfyUI")
            return
        }
        openURL(url)
    }

    @MainActor
    private func generate() async {
        guard serverOnline else {
            showMessage("ComfyUI offline. Проверь адрес во вкладке Settings.")
            panel = .settings
            return
        }

        guard let prompt = store.preparedPrompt(
            disabledNodeIDs: disabledReferenceNodeIDs
        ) else {
            showMessage("У выбранного workflow нет API prompt. Импортируй Save (API Format) JSON.")
            return
        }

        busy = true
        progress = 0.03
        statusText = "Отправляю workflow…"

        do {
            let promptID = try await ComfyClient.queue(
                base: serverURL,
                prompt: prompt
            )

            statusText = "В очереди · \(promptID.prefix(8))"
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
                        ? "Готово · output сохранён на ПК"
                        : "Готово · \(newResults.count) результат(а)"
                } else {
                    let remaining = max(0, 0.92 - progress)
                    progress = min(
                        0.92,
                        progress + max(0.002, remaining * 0.025)
                    )
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

private struct MiniStudioReferenceSlot: View {
    @EnvironmentObject private var store: WorkflowStore

    let index: Int
    let role: String
    let material: WorkflowMaterial?
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
                matching: material?.kind == .video ? .videos : .images
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
                                : Color.mint
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    Text("Picture \(index)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(7)

                    if material != nil && !enabled {
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
            .disabled(material == nil || !enabled || uploading)
            .onChange(of: selection) { item in
                guard let item else { return }
                Task { await importItem(item) }
            }
            .task(id: material?.currentValue) {
                await loadExistingPreview()
            }

            Text(role)
                .font(.caption.bold())
                .lineLimit(2)

            HStack {
                Text(
                    material == nil
                        ? "Missing"
                        : enabled
                            ? "Active"
                            : "Bypass"
                )
                .font(.caption2)
                .foregroundStyle(
                    material == nil
                        ? Color.secondary
                        : enabled
                            ? Color.mint
                            : Color.secondary
                )

                Spacer()

                if material != nil {
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
                    material != nil && enabled
                        ? Color.mint.opacity(0.18)
                        : Color.white.opacity(0.05),
                    lineWidth: 1
                )
        )
    }

    @MainActor
    private func loadExistingPreview() async {
        guard previewImage == nil,
              let material,
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
        guard let material else { return }

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
                .foregroundStyle(.mint)

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

private struct NativeParameterEditor: View {
    @EnvironmentObject private var store: WorkflowStore

    let parameter: WorkflowParameter
    let multiline: Bool
    let promptActions: Bool

    @State private var value: String
    @FocusState private var textFocused: Bool

    init(
        parameter: WorkflowParameter,
        multiline: Bool,
        promptActions: Bool = false
    ) {
        self.parameter = parameter
        self.multiline = multiline
        self.promptActions = promptActions
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
        HStack(spacing: 10) {
            TextField("Seed", text: $value)
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
                        .scaledToFill()
                        .aspectRatio(16.0 / 10.0, contentMode: .fill)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 18)
                        )
                }

            case .video:
                VStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.mint)

                    Text(result.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

            case .audio:
                VStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.mint)

                    Text(result.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

            case .file:
                VStack(spacing: 10) {
                    Image(systemName: "doc.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.mint)

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
                    .foregroundStyle(.mint)
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
                            .foregroundStyle(.mint)

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
                        .tint(.mint)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 28)
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
                    Label(
                        "Поделиться / сохранить",
                        systemImage: "square.and.arrow.up"
                    )
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
