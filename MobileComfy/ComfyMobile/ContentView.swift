import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: WorkflowStore
    @AppStorage("comfyServerURL") private var serverURL = "http://100.x.x.x:8188"

    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var showingEditor = false
    @State private var serverOnline = false
    @State private var busy = false
    @State private var statusText = "Не проверено"

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
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
                importFile(result)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(serverURL: $serverURL)
            }
            .fullScreenCover(isPresented: $showingEditor) {
                if let item = store.selected {
                    EditorScreen(serverURL: serverURL, item: item)
                        .environmentObject(store)
                }
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
                .foregroundStyle(.secondary)
        }
    }

    private var workflowSection: some View {
        Section("Workflow") {
            if store.workflows.isEmpty {
                ContentUnavailableView("Нет workflow", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Импортируй JSON из ComfyUI"))
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
                    HStack {
                        Label(item.apiPromptJSON != nil ? "Готов к генерации" : "Открой редактор для API prompt",
                              systemImage: item.apiPromptJSON != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(item.apiPromptJSON != nil ? .green : .orange)
                        Spacer()
                    }

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
                Label("Импорт JSON", systemImage: "square.and.arrow.down")
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
                         ? "После синхронизации из редактора здесь автоматически появятся prompt, seed, steps, CFG и другие параметры."
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
            Text("Редактор — это настоящий интерфейс ComfyUI. Изменения графа автоматически возвращаются в приложение.")
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            try store.importJSON(data: data, suggestedName: url.deletingPathExtension().lastPathComponent)
            statusText = "Workflow импортирован"
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func checkServer() async {
        serverOnline = await ComfyClient.check(base: serverURL)
        statusText = serverOnline ? "Соединение с ComfyUI установлено" : "ComfyUI недоступен"
    }

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

    var body: some View {
        NavigationStack {
            Form {
                Section("Адрес ComfyUI") {
                    TextField("http://100.x.x.x:8188", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Можно использовать LAN-адрес или Tailscale IP компьютера.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Подключение")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
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
