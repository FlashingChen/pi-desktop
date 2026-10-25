import SwiftUI
import AppKit

struct ModelConfigurationDraft: Identifiable {
    var provider = ""
    var baseURL = ""
    var api = "openai-completions"
    var apiKey = ""
    var modelID = ""
    var name = ""
    var contextWindow = 128000
    var maxTokens = 16384
    var reasoning = false
    var images = false
    var id: String { provider + "/" + modelID }
}

/// Edits only the chosen provider/model in Pi's own configuration file.
enum NativeModelConfiguration {
    static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PiError.message("models.json 必须是 JSON 对象。") }
        return json
    }
    static func models(in json: [String: Any]) -> [ModelConfigurationDraft] {
        let providers = json["providers"] as? [String: [String: Any]] ?? [:]
        return providers.keys.sorted().flatMap { id -> [ModelConfigurationDraft] in
            let provider = providers[id] ?? [:]
            return (provider["models"] as? [[String: Any]] ?? []).compactMap { model -> ModelConfigurationDraft? in
                guard let modelID = model["id"] as? String else { return nil }
                return ModelConfigurationDraft(provider:id,baseURL:model["baseUrl"] as? String ?? provider["baseUrl"] as? String ?? "",api:model["api"] as? String ?? provider["api"] as? String ?? "openai-completions",modelID:modelID,name:model["name"] as? String ?? modelID,contextWindow:model["contextWindow"] as? Int ?? 128000,maxTokens:model["maxTokens"] as? Int ?? 16384,reasoning:model["reasoning"] as? Bool ?? false,images:(model["input"] as? [String] ?? []).contains("image"))
            }
        }
    }
    static func saving(_ draft: ModelConfigurationDraft, into original: [String: Any]) throws -> [String: Any] {
        guard !draft.provider.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, !draft.modelID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw PiError.message("请填写提供商 ID 和模型 ID。") }
        guard let url = URL(string:draft.baseURL), ["https","http"].contains(url.scheme), url.host != nil else { throw PiError.message("请输入有效的 HTTP 或 HTTPS API 地址。") }
        guard draft.contextWindow > 0, draft.maxTokens > 0, draft.maxTokens <= draft.contextWindow else { throw PiError.message("输出上限必须大于 0，且不超过上下文窗口。") }
        var json=original, providers=json["providers"] as? [String:[String:Any]] ?? [:]
        var provider=providers[draft.provider] ?? [:]
        if provider["api"] == nil { provider["api"]=draft.api }
        // Empty input preserves any existing key, environment expression or OAuth setup.
        if !draft.apiKey.isEmpty { provider["apiKey"]=draft.apiKey }
        var models=provider["models"] as? [[String:Any]] ?? []
        let existing=models.firstIndex { $0["id"] as? String == draft.modelID }
        var model=existing.map { models[$0] } ?? [:]
        if model["baseUrl"] != nil { model["baseUrl"]=draft.baseURL }
        else { provider["baseUrl"]=draft.baseURL }
        model["id"]=draft.modelID;model["name"]=draft.name.isEmpty ? draft.modelID : draft.name
        model["api"]=draft.api;model["contextWindow"]=draft.contextWindow;model["maxTokens"]=draft.maxTokens
        model["reasoning"]=draft.reasoning;model["input"]=draft.images ? ["text","image"] : ["text"]
        if let existing { models[existing]=model } else { models.append(model) }
        provider["models"]=models;providers[draft.provider]=provider;json["providers"]=providers
        return json
    }
    static func write(_ draft: ModelConfigurationDraft, to url: URL, expected: Data?) throws {
        let current=try? Data(contentsOf:url)
        guard current == expected else { throw PiError.message("配置文件已被其他程序修改，请重新载入后保存。") }
        let json=try saving(draft,into:read(url))
        let data=try JSONSerialization.data(withJSONObject:json,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}

@MainActor
final class ModelConfigurationEditor: ObservableObject {
    @Published var entries:[ModelConfigurationDraft]=[]
    @Published var draft=ModelConfigurationDraft()
    @Published var error:String?
    @Published var notice=""
    private var source:Data?
    private var url:URL?
    func load(_ url:URL) {
        self.url=url;source=try? Data(contentsOf:url)
        do { entries=NativeModelConfiguration.models(in:try NativeModelConfiguration.read(url));error=nil }
        catch { self.error=error.localizedDescription }
    }
    func save() {
        guard let url else { return }
        do {
            try NativeModelConfiguration.write(draft,to:url,expected:source)
            draft.apiKey="";load(url)
            notice="已保存到 Pi 原生配置；当前任务不受影响。空闲后重新加载即可使用。"
        } catch { self.error=error.localizedDescription }
    }
}

struct ModelConfigurationView: View {
    var configurationURL:URL? = nil
    @EnvironmentObject var model:AppModel
    @StateObject private var editor=ModelConfigurationEditor()
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Text("模型配置").font(.system(size:17,weight:.semibold));Spacer()
                Button("添加模型") { editor.draft=ModelConfigurationDraft();editor.notice="" }
            }
            Text("添加兼容接口，或编辑已配置的模型。配置直接供 Pi CLI 与桌面端共用。")
                .font(.system(size:12)).foregroundStyle(Theme.secondary)
            if !editor.entries.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing:5) {
                        ForEach(editor.entries) { entry in
                            Button { editor.draft=entry;editor.notice="" } label: {
                                VStack(alignment:.leading,spacing:2) {
                                    Text(entry.name).font(.system(size:12));Text(entry.id).font(.system(size:10)).foregroundStyle(Theme.secondary)
                                }.padding(8)
                            }.buttonStyle(PiButtonStyle(kind:.row,selected:entry.id == editor.draft.id,horizontalPadding:0,verticalPadding:0))
                        }
                    }
                }.frame(height:52)
            }
            Grid(alignment:.leading,horizontalSpacing:14,verticalSpacing:12) {
                GridRow { Text("提供商 ID");TextField("例如 my-provider",text:$editor.draft.provider) }
                GridRow { Text("API 地址");TextField("API 基础地址",text:$editor.draft.baseURL) }
                GridRow {
                    Text("API 格式")
                    Picker("API 格式",selection:$editor.draft.api) {
                        ForEach(["openai-completions","openai-responses","anthropic-messages","google-generative-ai"],id:\.self) { Text($0).tag($0) }
                        if !["openai-completions","openai-responses","anthropic-messages","google-generative-ai"].contains(editor.draft.api) { Text(editor.draft.api).tag(editor.draft.api) }
                    }.labelsHidden()
                }
                GridRow { Text("API Key");SecureField("留空保留现有凭据；支持 $环境变量",text:$editor.draft.apiKey) }
                GridRow { Text("模型 ID");TextField("接口实际接收的模型 ID",text:$editor.draft.modelID) }
                GridRow { Text("显示名称");TextField("可选",text:$editor.draft.name) }
                GridRow { Text("上下文窗口");TextField("Tokens",value:$editor.draft.contextWindow,format:.number.grouping(.never)) }
                GridRow { Text("输出上限");TextField("Tokens",value:$editor.draft.maxTokens,format:.number.grouping(.never)) }
                GridRow {
                    Text("能力")
                    HStack(spacing:18) { Toggle("思考",isOn:$editor.draft.reasoning);Toggle("图片输入",isOn:$editor.draft.images) }
                }
            }.font(.system(size:12)).textFieldStyle(.roundedBorder)
            if let error=editor.error { Text(error).font(.system(size:12)).foregroundStyle(.red) }
            if !editor.notice.isEmpty { Text(editor.notice).font(.system(size:12)).foregroundStyle(Theme.secondary) }
            HStack {
                Button("在 Finder 中显示配置") { NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:model.agentDirectory.path) }
                Spacer()
                Button("重新加载") { Task { await model.reconnect() } }.disabled(!model.canSwitch || !model.connected)
                Button("保存模型") { editor.save() }.buttonStyle(PiButtonStyle(kind:.accent))
            }.font(.system(size:12))
            Text("提供商凭据共用，模型的独立地址会保留。OAuth 登录仍通过 Pi CLI 完成。")
                .font(.system(size:11)).foregroundStyle(Theme.secondary)
        }.onAppear { editor.load(configurationURL ?? model.agentDirectory.appendingPathComponent("models.json")) }
    }
}
