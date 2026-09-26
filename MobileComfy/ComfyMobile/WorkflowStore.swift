import Foundation
import SwiftUI

struct WorkflowItem: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var workflowJSON: Data?
    var apiPromptJSON: Data?
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, workflowJSON: Data? = nil, apiPromptJSON: Data? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.workflowJSON = workflowJSON
        self.apiPromptJSON = apiPromptJSON
        self.updatedAt = updatedAt
    }
}

struct WorkflowParameter: Identifiable, Equatable {
    enum ValueKind: Equatable { case text, integer, decimal, boolean }

    let nodeID: String
    let nodeTitle: String
    let key: String
    let value: String
    let kind: ValueKind

    var id: String { nodeID + "." + key }
}

@MainActor
final class WorkflowStore: ObservableObject {
    @Published var workflows: [WorkflowItem] = []
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedWorkflowID") }
    }
    @Published var lastMessage: String = ""

    private let fileURL: URL
    private let interestingKeys: Set<String> = [
        "text", "prompt", "negative_prompt", "seed", "noise_seed", "steps", "cfg",
        "denoise", "width", "height", "frames", "frame_count", "length", "fps",
        "strength", "strength_model", "strength_clip", "lora_strength", "model_strength"
    ]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ComfyMobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("workflows.json")
        load()
    }

    var selected: WorkflowItem? {
        workflows.first(where: { $0.id == selectedID })
    }

    func select(_ id: UUID) {
        selectedID = id
    }

    func importJSON(data: Data, suggestedName: String) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        var workflowData: Data?
        var apiData: Data?

        if let dict = object as? [String: Any] {
            if dict["nodes"] is [Any] {
                workflowData = data
            }
            if isAPIPrompt(dict) {
                apiData = data
            }
            if let workflow = dict["workflow"] {
                workflowData = try? JSONSerialization.data(withJSONObject: workflow, options: [.prettyPrinted])
            }
            if let prompt = dict["prompt"] as? [String: Any], isAPIPrompt(prompt) {
                apiData = try? JSONSerialization.data(withJSONObject: prompt, options: [.prettyPrinted])
            }
            if let output = dict["output"] as? [String: Any], isAPIPrompt(output) {
                apiData = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted])
            }
        }

        guard workflowData != nil || apiData != nil else {
            throw NSError(domain: "ComfyMobile", code: 1, userInfo: [NSLocalizedDescriptionKey: "Это не похоже на ComfyUI workflow/API JSON"])
        }

        let clean = suggestedName.replacingOccurrences(of: ".json", with: "", options: [.caseInsensitive])
        let item = WorkflowItem(name: clean.isEmpty ? "Workflow" : clean, workflowJSON: workflowData, apiPromptJSON: apiData)
        workflows.insert(item, at: 0)
        selectedID = item.id
        save()
    }

    func delete(_ item: WorkflowItem) {
        workflows.removeAll { $0.id == item.id }
        if selectedID == item.id { selectedID = workflows.first?.id }
        save()
    }

    func rename(_ item: WorkflowItem, to name: String) {
        guard let i = workflows.firstIndex(where: { $0.id == item.id }) else { return }
        workflows[i].name = name
        workflows[i].updatedAt = Date()
        save()
    }

    func updateFromEditor(workflow: Any, output: Any?) {
        guard let id = selectedID, let i = workflows.firstIndex(where: { $0.id == id }) else { return }
        if JSONSerialization.isValidJSONObject(workflow) {
            workflows[i].workflowJSON = try? JSONSerialization.data(withJSONObject: workflow, options: [.prettyPrinted])
        }
        if let output, JSONSerialization.isValidJSONObject(output) {
            workflows[i].apiPromptJSON = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted])
        }
        workflows[i].updatedAt = Date()
        lastMessage = "Workflow синхронизирован"
        save()
    }

    func parameters(for item: WorkflowItem) -> [WorkflowParameter] {
        guard let data = item.apiPromptJSON,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var result: [WorkflowParameter] = []
        for nodeID in root.keys.sorted(by: numericAwareLess) {
            guard let node = root[nodeID] as? [String: Any],
                  let inputs = node["inputs"] as? [String: Any] else { continue }
            let title = (node["_meta"] as? [String: Any])?["title"] as? String
                ?? node["class_type"] as? String
                ?? "Node " + nodeID

            for key in inputs.keys.sorted() where interestingKeys.contains(key.lowercased()) {
                guard let param = parameter(nodeID: nodeID, nodeTitle: title, key: key, raw: inputs[key] as Any) else { continue }
                result.append(param)
            }
        }
        return result
    }

    func setParameter(_ parameter: WorkflowParameter, value: String) {
        guard let id = selectedID,
              let i = workflows.firstIndex(where: { $0.id == id }),
              let data = workflows[i].apiPromptJSON,
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var node = root[parameter.nodeID] as? [String: Any],
              var inputs = node["inputs"] as? [String: Any] else { return }

        switch parameter.kind {
        case .integer:
            if let v = Int64(value) { inputs[parameter.key] = NSNumber(value: v) }
        case .decimal:
            if let v = Double(value.replacingOccurrences(of: ",", with: ".")) { inputs[parameter.key] = NSNumber(value: v) }
        case .boolean:
            inputs[parameter.key] = (value as NSString).boolValue
        case .text:
            inputs[parameter.key] = value
        }

        node["inputs"] = inputs
        root[parameter.nodeID] = node
        workflows[i].apiPromptJSON = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        workflows[i].updatedAt = Date()
        save()
    }

    func apiPromptObject() -> [String: Any]? {
        guard let data = selected?.apiPromptJSON else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func parameter(nodeID: String, nodeTitle: String, key: String, raw: Any) -> WorkflowParameter? {
        if let value = raw as? String {
            return WorkflowParameter(nodeID: nodeID, nodeTitle: nodeTitle, key: key, value: value, kind: .text)
        }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return WorkflowParameter(nodeID: nodeID, nodeTitle: nodeTitle, key: key, value: number.boolValue ? "true" : "false", kind: .boolean)
            }
            let double = number.doubleValue
            if floor(double) == double {
                return WorkflowParameter(nodeID: nodeID, nodeTitle: nodeTitle, key: key, value: String(number.int64Value), kind: .integer)
            }
            return WorkflowParameter(nodeID: nodeID, nodeTitle: nodeTitle, key: key, value: String(double), kind: .decimal)
        }
        return nil
    }

    private func isAPIPrompt(_ dict: [String: Any]) -> Bool {
        guard !dict.isEmpty else { return false }
        return dict.values.contains { value in
            guard let node = value as? [String: Any] else { return false }
            return node["class_type"] is String && node["inputs"] is [String: Any]
        }
    }

    private func numericAwareLess(_ a: String, _ b: String) -> Bool {
        if let ia = Int(a), let ib = Int(b) { return ia < ib }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(workflows) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([WorkflowItem].self, from: data) {
            workflows = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: "selectedWorkflowID"),
           let id = UUID(uuidString: raw),
           workflows.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = workflows.first?.id
        }
    }
}
