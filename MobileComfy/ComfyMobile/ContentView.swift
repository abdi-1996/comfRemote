import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: WorkflowStore
    @AppStorage("comfyServerURL") private var serverURL = "http://100.x.x.x:8188"

    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var showingEditor = false
    @State private var showingServerBrowser = false
    @State private var serverOnline = false
    @State private var busy = false
    @State private var statusText = "Не проверено"
    @State private var importAlertTitle = ""
    @State private var importAlertMessage = ""
    @State private var showingImportAlert = false

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                workflowSection
                parameterSection
                actionSection
            }
            .navigationTitle("Comfy Mobile")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .refreshable { await checkServer() }
            .task { await checkServer() }
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
            .sheet(isPresented: $showingSettings) {
                SettingsView(serverURL: $serverURL) {
                    Task { await checkServer() }
                }
            }
            .fullScreenCover(isPresented: $showingEditor) {
                if let item = store.selected {
                    EditorScreen(serverURL: serverURL, item: item)
                        .environmentObject(store)
                }
            }
            .fullScreenCover(isPresented: $showingServerBrowser) {
                ServerBrowserScreen(serverURL: serverURL)
            }
            .alert(importAlertTitle, isPresented: $showingImportAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importAlertMessage)
            }
        }
    }

    private var connectionSection: some View {
        Section("ComfyUI") {
            HStack {
                Circle()
                    .fill(serverOnline ? .green : .red)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(serverOnline ? "Online" : "Offline")
                        .font(.headline)
                    Text(serverURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Проверить") {
                    Task { await checkServer() }
                }
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(serverOnline ? .green : .secondary)
                .textSelection(.enabled)

            Button {
                showingServerBrowser = true
            } label: {
                Label("Открыть ComfyUI для проверки", systemImage: "safari")
            }
        }
    }

    private var workflowSection: some View {
        Section("Workflow") {
            if store.workflows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Нет workflow", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    Text("Нажми «Импорт JSON» и выбери обычный workflow, сохранённый из ComfyUI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Выбран", selection: Binding(
                    get: { store.selectedID ?? store.workflows.first!.id },
                    set: { store.select($0) }
                )) {
                    ForEach(store.workflows) { item in
                        Text(item.name).tag(item.id)
                    }
                }

                if let item = store.selected {
                    Label(
                        item.apiPromptJSON != nil ? "Готов к генерации" : "Импортирован • открой редактор для API prompt",
                        systemImage: item.apiPromptJSON != nil ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(item.apiPromptJSON != nil ? .green : .orange)

                    Button {
                        showingEditor = true
                    } label: {
                        Label("Редактировать в настоящем ComfyUI", systemImage: "square.grid.3x3.fill")
                    }

                    Button(role: .destructive) {
                        store.delete(item)
                    } label: {
                        Label("Удалить workflow", systemImage: "trash")
                    }
                }
            }

            Button {
                showingImporter = true
            } label: {
                Label("Импорт JSON из приложения «Файлы»", systemImage: "folder.badge.plus")
            }
        }
    }

    @ViewBuilder
    private var parameterSection: some View {
        if let item = store.selected {
            let parameters = store.parameters(for: item)
            Section("Настройки workflow") {
                if parameters.isEmpty {
                    Text(item.apiPromptJSON == nil
                         ? "Workflow импортирован. Открой его в редакторе ComfyUI — приложение автоматически получит API prompt."
                         : "В API workflow не найдено поддерживаемых редактируемых полей.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(parameters) { parameter in
                        ParameterRow(parameter: parameter) { newValue in
                            store.setParameter(parameter, value: newValue)
                        }
                    }
                }
            }
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await generate() }
            } label: {
                HStack {
                    Spacer()
                    if busy { ProgressView().padding(.trailing, 6) }
                    Label("GENERATE", systemImage: "sparkles")
                        .fontWeight(.bold)
                    Spacer()
                }
            }
            .disabled(busy || !serverOnline || store.selected?.apiPromptJSON == nil)
        } footer: {
            Text("Редактор — настоящий интерфейс ComfyUI. После изменения графа workflow автоматически синхронизируется обратно.")
        }
    }

    private func importFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                throw NSError(domain: "ComfyMobile", code: 2, userInfo: [NSLocalizedDescriptionKey: "Выбранный файл пустой"])
            }
            try store.importJSON(data: data, suggestedName: url.lastPathComponent)

            importAlertTitle = "Workflow импортирован"
            importAlertMessage = url.lastPathComponent + "\nТеперь можно открыть его в настоящем ComfyUI."
            showingImportAlert = true
        } catch {
            importAlertTitle = "Не удалось импортировать"
            importAlertMessage = error.localizedDescription
            showingImportAlert = true
        }
    }

    @MainActor
    private func checkServer() async {
        statusText = "Проверяю…"
        let result = await ComfyClient.check(base: serverURL)
        serverOnline = result.online
        statusText = result.message

        if let normalized = result.normalizedURL, normalized != serverURL {
            serverURL = normalized
        }
    }

    @MainActor
    private func generate() async {
        guard let prompt = store.apiPromptObject() else { return }
        busy = true
        defer { busy = false }

        do {
            let promptID = try await ComfyClient.queue(base: serverURL, prompt: prompt)
            statusText = "Запущено • prompt_id: " + promptID
        } catch {
            statusText = error.localizedDescription
        }
    }
}

private struct ParameterRow: View {
    let parameter: WorkflowParameter
    let onChange: (String) -> Void
    @State private var value: String

    init(parameter: WorkflowParameter, onChange: @escaping (String) -> Void) {
        self.parameter = parameter
        self.onChange = onChange
        _value = State(initialValue: parameter.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(parameter.key)
                    .font(.headline)
                Spacer()
                Text(parameter.nodeTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if parameter.kind == .boolean {
                Toggle("", isOn: Binding(
                    get: { (value as NSString).boolValue },
                    set: {
                        value = $0 ? "true" : "false"
                        onChange(value)
                    }
                ))
                .labelsHidden()
            } else if parameter.kind == .text {
                TextEditor(text: $value)
                    .frame(minHeight: 74)
                    .onChange(of: value) { _, newValue in onChange(newValue) }
            } else {
                TextField(parameter.key, text: $value)
                    .keyboardType(parameter.kind == .integer ? .numbersAndPunctuation : .decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onChange(value) }
                    .onChange(of: value) { _, newValue in onChange(newValue) }
            }
        }
        .onChange(of: parameter.value) { _, newValue in
            if value != newValue { value = newValue }
        }
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var serverURL: String
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Адрес ComfyUI") {
                    TextField("192.168.1.25:8188", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Text("Можно написать только IP:порт. Приложение само добавит http://. Для доступа вне дома используй Tailscale IP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("На ПК") {
                    Text("ComfyUI должен слушать сеть, например: python main.py --listen 0.0.0.0 --port 8188")
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Подключение")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить и проверить") {
                        dismiss()
                        onDone()
                    }
                }
            }
        }
    }
}

private struct EditorScreen: View {
    @EnvironmentObject private var store: WorkflowStore
    @Environment(\.dismiss) private var dismiss
    let serverURL: String
    let item: WorkflowItem
    @State private var message = "Открываю ComfyUI…"

    var body: some View {
        NavigationStack {
            ComfyEditorView(
                serverURL: serverURL,
                item: item,
                onSync: { workflow, output in
                    store.updateFromEditor(workflow: workflow, output: output)
                    message = "Синхронизировано"
                },
                onStatus: { message = $0 }
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("ComfyUI Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct ServerBrowserScreen: View {
    @Environment(\.dismiss) private var dismiss
    let serverURL: String

    var body: some View {
        NavigationStack {
            SimpleComfyBrowser(serverURL: serverURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Проверка ComfyUI")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Готово") { dismiss() }
                    }
                }
        }
    }
}
