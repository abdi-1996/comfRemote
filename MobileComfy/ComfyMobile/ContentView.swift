import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var store: WorkflowStore
    @AppStorage("comfyServerURL") private var serverURL = "http://100.x.x.x:8188"

    @State private var showingSettings = false
    @State private var busy = false
    @State private var statusText = ""

    var body: some View {
        NavigationStack {
            List {
                workflowHeader
                parameterSection
                actionSection
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    EmptyView()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(serverURL: $serverURL)
                    .environmentObject(store)
            }
        }
    }

    @ViewBuilder
    private var workflowHeader: some View {
        Section {
            if let item = store.selected {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.title2.bold())
                            .lineLimit(2)

                        if !statusText.isEmpty {
                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    Button {
                        openComfyInBrowser()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.title2.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Открыть workflow в ComfyUI")
                }
                .padding(.vertical, 4)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workflow не выбран")
                            .font(.title2.bold())
                        Text("Добавь workflow в настройках")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder
    private var parameterSection: some View {
        if let item = store.selected {
            let parameters = store.parameters(for: item)
            Section {
                if parameters.isEmpty {
                    Text(item.apiPromptJSON == nil
                         ? "Для этого workflow пока нет API-параметров. Настрой импорт в ⚙️."
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
                    if busy {
                        ProgressView()
                            .padding(.trailing, 6)
                    }
                    Label("GENERATE", systemImage: "sparkles")
                        .fontWeight(.bold)
                    Spacer()
                }
            }
            .disabled(busy || store.selected?.apiPromptJSON == nil)
        }
    }

    private func openComfyInBrowser() {
        guard let url = ComfyClient.normalizedBaseURL(serverURL) else {
            statusText = "Неверный адрес ComfyUI. Исправь его в ⚙️."
            return
        }

        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                Task { @MainActor in
                    statusText = "Не удалось открыть Safari"
                }
            }
        }
    }

    @MainActor
    private func generate() async {
        guard let prompt = store.apiPromptObject() else {
            statusText = "У workflow нет API prompt"
            return
        }

        busy = true
        defer { busy = false }

        do {
            let promptID = try await ComfyClient.queue(base: serverURL, prompt: prompt)
            statusText = "Запущено • " + promptID
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
                    .onChange(of: value) { _, newValue in
                        onChange(newValue)
                    }
            } else {
                TextField(parameter.key, text: $value)
                    .keyboardType(parameter.kind == .integer ? .numbersAndPunctuation : .decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        onChange(value)
                    }
                    .onChange(of: value) { _, newValue in
                        onChange(newValue)
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

    var body: some View {
        NavigationStack {
            Form {
                comfySection
                workflowSection
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
                        Task { await checkServer() }
                    }
                }
            }

            Button {
                openComfyInBrowser()
            } label: {
                Label("Открыть ComfyUI в Safari", systemImage: "safari")
            }

            Text("ComfyUI на ПК должен быть запущен с --listen 0.0.0.0 --port 8188")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var workflowSection: some View {
        Section("Workflow") {
            if store.workflows.isEmpty {
                Text("Workflow пока не добавлены")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Выбранный workflow", selection: Binding(
                    get: { store.selectedID ?? store.workflows.first!.id },
                    set: { store.select($0) }
                )) {
                    ForEach(store.workflows) { item in
                        Text(item.name).tag(item.id)
                    }
                }

                if let item = store.selected {
                    Text(item.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
