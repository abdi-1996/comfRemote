import Foundation
import SwiftUI

struct WorkflowItem: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var workflowJSON: Data?
    var apiPromptJSON: Data?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        workflowJSON: Data? = nil,
        apiPromptJSON: Data? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.workflowJSON = workflowJSON
        self.apiPromptJSON = apiPromptJSON
        self.updatedAt = updatedAt
    }
}

struct WorkflowParameter: Identifiable, Equatable {
    enum ValueKind: Equatable {
        case text
        case integer
        case decimal
        case boolean
    }

    let nodeID: String
    let nodeTitle: String
    let classType: String
    let key: String
    let value: String
    let kind: ValueKind

    var id: String { nodeID + "." + key }
}

struct WorkflowNodeGroup: Identifiable, Equatable {
    let nodeID: String
    let title: String
    let classType: String
    let parameters: [WorkflowParameter]

    var id: String { nodeID }
}

struct WorkflowMaterial: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case image
        case video

        var title: String {
            switch self {
            case .image: return "Фото"
            case .video: return "Видео"
            }
        }
    }

    let nodeID: String
    let nodeTitle: String
    let classType: String
    let key: String
    let currentValue: String
    let kind: Kind

    var id: String { nodeID + "." + key }
}

@MainActor
final class WorkflowStore: ObservableObject {
    @Published var workflows: [WorkflowItem] = []
    @Published var selectedID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedWorkflowID")
        }
    }
    @Published var lastMessage: String = ""

    private let fileURL: URL

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
            throw NSError(
                domain: "ComfyMobile",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Это не похоже на ComfyUI workflow/API JSON"]
            )
        }

        let clean = suggestedName.replacingOccurrences(of: ".json", with: "", options: [.caseInsensitive])
        let item = WorkflowItem(
            name: clean.isEmpty ? "Workflow" : clean,
            workflowJSON: workflowData,
            apiPromptJSON: apiData
        )
        workflows.insert(item, at: 0)
        selectedID = item.id
        save()
    }

    func delete(_ item: WorkflowItem) {
        UserDefaults.standard.removeObject(forKey: exposureKey(item.id))
        workflows.removeAll { $0.id == item.id }
        if selectedID == item.id {
            selectedID = workflows.first?.id
        }
        save()
    }

    func rename(_ item: WorkflowItem, to name: String) {
        guard let i = workflows.firstIndex(where: { $0.id == item.id }) else { return }
        workflows[i].name = name
        workflows[i].updatedAt = Date()
        save()
    }

    func updateFromEditor(workflow: Any, output: Any?) {
        guard let id = selectedID,
              let i = workflows.firstIndex(where: { $0.id == id }) else { return }

        if JSONSerialization.isValidJSONObject(workflow) {
            workflows[i].workflowJSON = try? JSONSerialization.data(
                withJSONObject: workflow,
                options: [.prettyPrinted]
            )
        }

        if let output, JSONSerialization.isValidJSONObject(output) {
            workflows[i].apiPromptJSON = try? JSONSerialization.data(
                withJSONObject: output,
                options: [.prettyPrinted]
            )
        }

        workflows[i].updatedAt = Date()
        lastMessage = "Workflow синхронизирован"
        save()
    }

    func allParameters(for item: WorkflowItem) -> [WorkflowParameter] {
        guard let root = apiRoot(for: item) else { return [] }

        var result: [WorkflowParameter] = []

        for nodeID in root.keys.sorted(by: numericAwareLess) {
            guard let node = root[nodeID] as? [String: Any],
                  let inputs = node["inputs"] as? [String: Any] else { continue }

            let classType = node["class_type"] as? String ?? "Node"
            let title = (node["_meta"] as? [String: Any])?["title"] as? String
                ?? classType
                ?? "Node " + nodeID

            for key in inputs.keys.sorted() {
                let raw = inputs[key] as Any

                if materialKind(classType: classType, key: key, raw: raw) != nil {
                    continue
                }

                if let param = parameter(
                    nodeID: nodeID,
                    nodeTitle: title,
                    classType: classType,
                    key: key,
                    raw: raw
                ) {
                    result.append(param)
                }
            }
        }

        return result
    }

    func nodeGroups(for item: WorkflowItem) -> [WorkflowNodeGroup] {
        let params = allParameters(for: item)
        let grouped = Dictionary(grouping: params, by: { $0.nodeID })

        return grouped.keys.sorted(by: numericAwareLess).compactMap { nodeID in
            guard let values = grouped[nodeID], let first = values.first else { return nil }
            return WorkflowNodeGroup(
                nodeID: nodeID,
                title: first.nodeTitle,
                classType: first.classType,
                parameters: values
            )
        }
    }

    func materials(for item: WorkflowItem) -> [WorkflowMaterial] {
        guard let root = apiRoot(for: item) else { return [] }

        var result: [WorkflowMaterial] = []

        for nodeID in root.keys.sorted(by: numericAwareLess) {
            guard let node = root[nodeID] as? [String: Any],
                  let inputs = node["inputs"] as? [String: Any] else { continue }

            let classType = node["class_type"] as? String ?? "Node"
            let title = (node["_meta"] as? [String: Any])?["title"] as? String ?? classType

            for key in inputs.keys.sorted() {
                let raw = inputs[key] as Any
                guard let kind = materialKind(classType: classType, key: key, raw: raw),
                      let current = raw as? String else { continue }

                result.append(
                    WorkflowMaterial(
                        nodeID: nodeID,
                        nodeTitle: title,
                        classType: classType,
                        key: key,
                        currentValue: current,
                        kind: kind
                    )
                )
            }
        }

        return result
    }

    func primaryPromptParameter(for item: WorkflowItem) -> WorkflowParameter? {
        let params = allParameters(for: item)
        let preferred = ["prompt", "positive_prompt", "text"]

        for key in preferred {
            if let match = params.first(where: {
                $0.key.lowercased() == key && $0.kind == .text
            }) {
                return match
            }
        }

        return params.first(where: {
            $0.kind == .text &&
            ($0.key.lowercased().contains("prompt") || $0.key.lowercased().contains("text"))
        })
    }

    func primarySeedParameter(for item: WorkflowItem) -> WorkflowParameter? {
        let params = allParameters(for: item)
        let preferred = ["seed", "noise_seed"]

        for key in preferred {
            if let match = params.first(where: {
                $0.key.lowercased() == key &&
                ($0.kind == .integer || $0.kind == .decimal)
            }) {
                return match
            }
        }

        return params.first(where: {
            $0.key.lowercased().contains("seed") &&
            ($0.kind == .integer || $0.kind == .decimal)
        })
    }

    func studioParameters(
        for item: WorkflowItem,
        classContains: [String] = [],
        titleContains: [String] = [],
        keys: [String] = []
    ) -> [WorkflowParameter] {
        let classNeedles = classContains.map { $0.lowercased() }
        let titleNeedles = titleContains.map { $0.lowercased() }
        let keyNeedles = keys.map { $0.lowercased() }

        return allParameters(for: item).filter { parameter in
            let classText = parameter.classType.lowercased()
            let titleText = parameter.nodeTitle.lowercased()
            let keyText = parameter.key.lowercased()

            let classMatch = classNeedles.isEmpty || classNeedles.contains(where: { classText.contains($0) })
            let titleMatch = titleNeedles.isEmpty || titleNeedles.contains(where: { titleText.contains($0) })
            let keyMatch = keyNeedles.isEmpty || keyNeedles.contains(where: {
                keyText == $0 || keyText.contains($0)
            })

            return classMatch && titleMatch && keyMatch
        }
    }

    func firstStudioParameter(
        for item: WorkflowItem,
        classContains: [String] = [],
        titleContains: [String] = [],
        keys: [String]
    ) -> WorkflowParameter? {
        let exactKeys = keys.map { $0.lowercased() }

        let candidates = studioParameters(
            for: item,
            classContains: classContains,
            titleContains: titleContains,
            keys: keys
        )

        for key in exactKeys {
            if let match = candidates.first(where: { $0.key.lowercased() == key }) {
                return match
            }
        }

        return candidates.first
    }

    func exposedParameters(for item: WorkflowItem) -> [WorkflowParameter] {
        let ids = exposedIDs(for: item.id)
        let pinned = Set([
            primaryPromptParameter(for: item)?.id,
            primarySeedParameter(for: item)?.id
        ].compactMap { $0 })

        return allParameters(for: item).filter {
            ids.contains($0.id) && !pinned.contains($0.id)
        }
    }

    func isExposed(_ parameter: WorkflowParameter, in item: WorkflowItem) -> Bool {
        if parameter.id == primaryPromptParameter(for: item)?.id { return true }
        if parameter.id == primarySeedParameter(for: item)?.id { return true }
        return exposedIDs(for: item.id).contains(parameter.id)
    }

    func isPinned(_ parameter: WorkflowParameter, in item: WorkflowItem) -> Bool {
        parameter.id == primaryPromptParameter(for: item)?.id
            || parameter.id == primarySeedParameter(for: item)?.id
    }

    func toggleExposed(_ parameter: WorkflowParameter, in item: WorkflowItem) {
        guard !isPinned(parameter, in: item) else { return }

        var ids = exposedIDs(for: item.id)
        if ids.contains(parameter.id) {
            ids.remove(parameter.id)
        } else {
            ids.insert(parameter.id)
        }

        UserDefaults.standard.set(Array(ids).sorted(), forKey: exposureKey(item.id))
        objectWillChange.send()
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
            if let v = Int64(value) {
                inputs[parameter.key] = NSNumber(value: v)
            }
        case .decimal:
            if let v = Double(value.replacingOccurrences(of: ",", with: ".")) {
                inputs[parameter.key] = NSNumber(value: v)
            }
        case .boolean:
            inputs[parameter.key] = (value as NSString).boolValue
        case .text:
            inputs[parameter.key] = value
        }

        node["inputs"] = inputs
        root[parameter.nodeID] = node
        workflows[i].apiPromptJSON = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted]
        )
        workflows[i].updatedAt = Date()
        save()
    }

    func setMaterial(_ material: WorkflowMaterial, remoteName: String) {
        guard let id = selectedID,
              let i = workflows.firstIndex(where: { $0.id == id }),
              let data = workflows[i].apiPromptJSON,
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var node = root[material.nodeID] as? [String: Any],
              var inputs = node["inputs"] as? [String: Any] else { return }

        inputs[material.key] = remoteName
        node["inputs"] = inputs
        root[material.nodeID] = node

        workflows[i].apiPromptJSON = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted]
        )
        workflows[i].updatedAt = Date()
        save()
    }

    func apiPromptObject() -> [String: Any]? {
        guard let data = selected?.apiPromptJSON else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func preparedPrompt(disabledNodeIDs: Set<String>) -> [String: Any]? {
        guard var root = apiPromptObject() else { return nil }
        guard !disabledNodeIDs.isEmpty else { return root }

        for nodeID in disabledNodeIDs {
            root.removeValue(forKey: nodeID)
        }

        for nodeID in Array(root.keys) {
            guard var node = root[nodeID] as? [String: Any],
                  var inputs = node["inputs"] as? [String: Any] else { continue }

            for key in Array(inputs.keys) {
                guard let link = inputs[key] as? [Any],
                      let source = link.first else { continue }

                let sourceID: String
                if let string = source as? String {
                    sourceID = string
                } else if let number = source as? NSNumber {
                    sourceID = number.stringValue
                } else {
                    continue
                }

                if disabledNodeIDs.contains(sourceID) {
                    inputs.removeValue(forKey: key)
                }
            }

            node["inputs"] = inputs
            root[nodeID] = node
        }

        return root
    }

    private func apiRoot(for item: WorkflowItem) -> [String: Any]? {
        guard let data = item.apiPromptJSON else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func parameter(
        nodeID: String,
        nodeTitle: String,
        classType: String,
        key: String,
        raw: Any
    ) -> WorkflowParameter? {
        if let value = raw as? String {
            return WorkflowParameter(
                nodeID: nodeID,
                nodeTitle: nodeTitle,
                classType: classType,
                key: key,
                value: value,
                kind: .text
            )
        }

        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return WorkflowParameter(
                    nodeID: nodeID,
                    nodeTitle: nodeTitle,
                    classType: classType,
                    key: key,
                    value: number.boolValue ? "true" : "false",
                    kind: .boolean
                )
            }

            let double = number.doubleValue
            if floor(double) == double {
                return WorkflowParameter(
                    nodeID: nodeID,
                    nodeTitle: nodeTitle,
                    classType: classType,
                    key: key,
                    value: String(number.int64Value),
                    kind: .integer
                )
            }

            return WorkflowParameter(
                nodeID: nodeID,
                nodeTitle: nodeTitle,
                classType: classType,
                key: key,
                value: String(double),
                kind: .decimal
            )
        }

        return nil
    }

    private func materialKind(classType: String, key: String, raw: Any) -> WorkflowMaterial.Kind? {
        guard raw is String else { return nil }

        let c = classType.lowercased()
        let k = key.lowercased()

        let imageClass =
            c.contains("loadimage") ||
            c.contains("imageinput") ||
            c.contains("inputimage") ||
            c.contains("referenceimage") ||
            c.contains("refimage") ||
            c.contains("picture")

        let videoClass =
            c.contains("loadvideo") ||
            c.contains("videoinput") ||
            c.contains("inputvideo") ||
            c.contains("referencevideo") ||
            c.contains("refvideo") ||
            c.contains("vhs_loadvideo")

        if (k == "image" || k == "image_path" || k == "image_file" || k == "filename")
            && (imageClass || c.contains("image")) {
            return .image
        }

        if (k == "video" || k == "video_path" || k == "video_file" || k == "filename")
            && (videoClass || c.contains("video")) {
            return .video
        }

        if imageClass && (k == "file" || k == "path" || k.contains("image") || k.contains("picture")) {
            return .image
        }

        if videoClass && (k == "file" || k == "path" || k.contains("video")) {
            return .video
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
        if let ia = Int(a), let ib = Int(b) {
            return ia < ib
        }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    private func exposureKey(_ workflowID: UUID) -> String {
        "exposedParameters." + workflowID.uuidString
    }

    private func exposedIDs(for workflowID: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: exposureKey(workflowID)) ?? [])
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
