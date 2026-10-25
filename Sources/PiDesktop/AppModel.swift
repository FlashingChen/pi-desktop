import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DraftBuffer: ObservableObject { @Published var text = "" }

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var project: Project?
    @Published var sessions: [String: [PiSession]] = [:]
    @Published var sessionPath: String?
    @Published var sessionName = "新会话"
    @Published var messages: [DisplayMessage] = [] { didSet { conversationItems = conversationRows(messages) } }
    private(set) var conversationItems: [ConversationRow] = []
    @Published var models: [PiModel] = []
    @Published var selectedModel: PiModel?
    @Published var thinking = "off"
    @Published var thinkingLevels = ["off"]
    @Published var commands: [PiCommand] = [] { didSet { commandIndex = CommandSearchIndex(commands) } }
    private(set) var commandIndex = CommandSearchIndex([])
    let draftBuffer = DraftBuffer()
    var draft: String { get { draftBuffer.text } set { draftBuffer.text = newValue } }
    @Published var commandsLoading = false
    @Published var commandsError: String?
    private var commandRequest = UUID()
    @Published var attachments: [ImageAttachment] = []
    let runActivity = RunActivity()
    @Published var busy = false { didSet { runActivity.update(running: busy || bashRunning) } }
    @Published var bashRunning = false { didSet { runActivity.update(running: busy || bashRunning) } }
    private var bashMessageIndex: Int?
    @Published var connecting = false
    @Published var connected = false
    @Published var error: String?
    @Published var status = ""
    @Published var extensionStatus: [String: String] = [:]
    @Published var widgets: [String: [String]] = [:]
    @Published var dialogs: [ExtensionDialog] = []
    @Published var terminal: TerminalSession?
    @Published var showSettings = false
    @Published var settingsSection = "general"
    @Published var renameTarget: PiSession?
    @Published var showCommands = false
    @Published var search = ""
    @Published var statistics = ""
    @Published var pendingCount = 0
    @Published var queueBehavior = "steer"
    @Published var forkSheetVisible = false
    @Published var forkPoints: [ForkPoint] = []
    @Published var autoCompaction = true
    @Published var autoRetry = true
    @Published var showCompactSheet = false
    @Published var executableOverride = UserDefaults.standard.string(forKey: "piExecutable") ?? ""
    @Published var sessionDirectory = UserDefaults.standard.string(forKey: "sessionDirectory") ?? ""
    let connection = PiConnection()
    private(set) var environment: PiEnvironment?
    private struct DraftState { var text: String; var images: [ImageAttachment] }
    private var drafts: [String: DraftState] = [:]
    private var runGeneration = UUID()
    enum SwitchIntent { case newSession; case selectProject(Project, String?) }
    private var pendingIntent: SwitchIntent?
    private var streamingIndex: Int?
    private var refreshTimer: Timer?
    private var shuttingDown = false
    private var metadataGeneration = UUID()
    private var metadataTask: Task<Void, Never>?
    var canSwitch: Bool { !busy && !connecting && terminal == nil }
    var canSend: Bool { connected && !connecting && terminal == nil && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }

    init() {
        if let data = UserDefaults.standard.data(forKey: "projects"), let saved = try? JSONDecoder().decode([Project].self, from: data) { projects = saved }
        connection.onEvent = { [weak self] in self?.event($0) }
        connection.onExit = { [weak self] reason in
            guard let self, !self.shuttingDown else { return }
            self.connected = false; self.busy = false; self.bashRunning = false
            self.error = reason?.isEmpty == false ? reason : "Pi CLI 已退出。点击重连可继续会话。"
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshSessions() }
        }
    }
    func boot() async {
        guard project == nil else { return }
        let last = UserDefaults.standard.string(forKey: "lastProject")
        if let first = projects.first(where: { $0.path == last }) ?? projects.first { await selectProject(first) }
        else {
            do { environment = try await PiEnvironment.resolve(override: executableOverride) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func persistProjects() {
        UserDefaults.standard.set(try? JSONEncoder().encode(projects), forKey: "projects")
    }
    func openProject() {
        guard canSwitch else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "打开项目"; panel.message = "Pi 将在此目录加载原生配置、Skills 和 Extensions。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let item = Project(path: url.resolvingSymlinksInPath().standardizedFileURL.path)
        if !projects.contains(item) { projects.append(item); persistProjects() }
        Task { await selectProject(item) }
    }
    func openURL(_ url: URL) {
        guard canSwitch else { error = "请等待当前操作结束后再打开项目或会话。"; return }
        if url.pathExtension == "jsonl", let data = try? Data(contentsOf: url), let line = data.split(separator: 10).first,
           let header = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let cwd = header["cwd"] as? String {
            let item = Project(path: cwd)
            if !projects.contains(item) { projects.append(item); persistProjects() }
            Task { await selectProject(item, session: url.path) }
        } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let item = Project(path: url.resolvingSymlinksInPath().path)
            if !projects.contains(item) { projects.append(item); persistProjects() }
            Task { await selectProject(item) }
        } else { error = "请选择项目文件夹或 Pi 原生 .jsonl 会话文件。" }
    }
    func removeProject(_ item: Project) {
        guard canSwitch else { return }
        projects.removeAll { $0.id == item.id }; persistProjects()
        if project == item {
            Task {
                await connection.stop(); project = nil; connected = false; messages = []; sessionPath = nil
                if let next = projects.first { await selectProject(next) }
            }
        }
    }
    func selectProject(_ item: Project, session: String? = nil) async {
        guard terminal == nil else { return }
        if connecting { pendingIntent = .selectProject(item, session) ; return }
        guard !busy else { status = "当前任务继续运行；完成或手动中止后可切换会话。"; return }
        saveDraft()
        metadataGeneration = UUID(); metadataTask?.cancel()
        connecting = true
        defer { finishConnecting() }
        connected = false; project = item; messages = []; sessionPath = session; sessionName = "新会话"
        clearSessionUI()
        models = []; commands = []; commandsError = nil; commandsLoading = false; selectedModel = nil; thinkingLevels = ["off"]
        error = nil
        restoreDraft()
        status = "正在连接 Pi，可以先写草稿…"
        await connection.stop()
        UserDefaults.standard.set(item.path, forKey: "lastProject")
        do {
            environment = try await PiEnvironment.resolve(override: executableOverride)
            try start(session: session, continueRecent: session == nil)
            try await syncAll()
            if draft.isEmpty && attachments.isEmpty { restoreDraft() }
            status = ""
            Task { await refreshSessions() }   // 会话列表后台刷新，不挡已就绪的界面
        } catch { self.error = error.localizedDescription; connected = false; status = "连接失败，草稿已保留" }
    }
    private func finishConnecting() {
        connecting = false
        guard let intent = pendingIntent else { return }
        pendingIntent = nil
        Task {
            switch intent {
            case .newSession: await newSession()
            case .selectProject(let item, let session): await selectProject(item, session: session)
            }
        }
    }
    private func start(session: String?, continueRecent: Bool) throws {
        guard let project, let environment else { throw PiError.message("请先打开项目。") }
        try connection.start(environment: environment, cwd: project.path, session: session, continueRecent: continueRecent, sessionDirectory: sessionDirectory)
    }
    func reconnect() async {
        if connecting { return }
        guard !busy else { status = "当前任务继续运行；完成或手动中止后可切换会话。"; return }
        guard terminal == nil else { return }
        PiEnvironment.invalidate(override:executableOverride)
        if let item = project { await selectProject(item, session: sessionPath) }
    }
    func refreshSessions() async {
        let folders = projects
        let env = environment?.variables ?? ProcessInfo.processInfo.environment
        let directory = sessionDirectory
        let activeDirectory = sessionPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        let activeProject = project?.path
        let result = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: folders.map { folder in
                var items = SessionIndex.list(project: folder.path, environment: env, override: directory)
                if folder.path == activeProject, let activeDirectory {
                    let additional = SessionIndex.list(project: folder.path, environment: env, override: activeDirectory)
                    let paths = Set(items.map(\.path))
                    items += additional.filter { !paths.contains($0.path) }
                    items.sort { $0.date > $1.date }
                }
                return (folder.id, items)
            })
        }.value
        sessions = result
        if sessionName == "新会话", let path = sessionPath, let title = result[project?.id ?? ""]?.first(where: { $0.path == path })?.title { sessionName = title }
    }
    private var draftKey: String { (project?.path ?? "") + "::" + (sessionPath ?? "new") }
    private func saveDraft() { if project != nil { drafts[draftKey] = DraftState(text: draft, images: attachments) } }
    private func restoreDraft() {
        let saved = drafts[draftKey]
        draft = saved?.text ?? ""; attachments = saved?.images ?? []
    }
    private func clearSessionUI() {
        attachments = []; streamingIndex = nil; draft = ""; pendingCount = 0
        extensionStatus = [:]; widgets = [:]; dialogs = []; status = ""; statistics = ""
    }
    func newSession() async {
        guard terminal == nil else { return }
        if connecting { pendingIntent = .newSession; return }
        guard !busy else { status = "当前任务继续运行；完成或手动中止后可切换会话。"; return }
        guard connected else { if let item = project { await selectProject(item) }; return }
        saveDraft()
        metadataGeneration = UUID(); metadataTask?.cancel()
        connecting = true; defer { finishConnecting() }
        do {
            let response = try await connection.request("new_session", timeout: 86400)
            if response["cancelled"] as? Bool == true { status = "Pi Extension 取消了新建会话。"; return }
            clearSessionUI(); try await syncAll(); restoreDraft(); await refreshSessions()
        } catch { self.error = error.localizedDescription }
    }
    func switchSession(_ session: PiSession, in item: Project) async {
        guard terminal == nil else { return }
        if connecting { pendingIntent = .selectProject(item, session.path); return }
        guard !busy else { status = "当前任务继续运行；完成或手动中止后可切换会话。"; return }
        if project != item { await selectProject(item, session: session.path); return }
        saveDraft()
        metadataGeneration = UUID(); metadataTask?.cancel()
        connecting = true; defer { finishConnecting() }
        do {
            let result = try await connection.request("switch_session", ["sessionPath": session.path], timeout: 86400)
            if result["cancelled"] as? Bool == true { status = "Pi Extension 取消了切换会话。"; return }
            clearSessionUI(); try await syncAll(); restoreDraft()
        } catch { self.error = error.localizedDescription }
    }
    func syncAll() async throws {
        // History gates sending. Optional discovery must never gate the editor.
        metadataTask?.cancel()
        let token = UUID(); metadataGeneration = token
        let state = try await connection.request("get_state")
        sessionPath = state["sessionFile"] as? String
        sessionName = state["sessionName"] as? String ?? "新会话"
        if sessionName == "新会话", let path = sessionPath, let title = sessions[project?.id ?? ""]?.first(where: { $0.path == path })?.title { sessionName = title }
        busy = state["isStreaming"] as? Bool ?? false
        selectedModel = (state["model"] as? [String: Any]).map(PiModel.init)
        thinking = state["thinkingLevel"] as? String ?? "off"
        pendingCount = state["pendingMessageCount"] as? Int ?? 0
        let history = try await connection.request("get_messages")
        messages = (history["messages"] as? [[String: Any]] ?? []).enumerated().map { DisplayMessage.from($0.element, index: $0.offset) }
        streamingIndex = nil
        connected = true; error = nil
        metadataTask = Task { [weak self] in await self?.loadMetadata(generation: token) }
    }
    private func loadMetadata(generation token: UUID) async {
        // Independent results are published independently; a slow model provider
        // cannot hide commands or fail an otherwise healthy session connection.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in await self?.refreshCommands() }
            for type in ["get_available_models", "get_available_thinking_levels", "get_session_stats"] {
                group.addTask { @MainActor [weak self] in
                    guard let self, let result = try? await self.connection.request(type),
                          !Task.isCancelled, self.metadataGeneration == token else { return }
                    switch type {
                    case "get_available_models": self.models = (result["models"] as? [[String: Any]] ?? []).map(PiModel.init)
                    case "get_available_thinking_levels": self.thinkingLevels = result["levels"] as? [String] ?? ["off"]
                    default: self.applyStatistics(result)
                    }
                }
            }
        }
    }
    func refreshCommands() async {
        guard connected, terminal == nil, !shuttingDown else { return }
        let generation = metadataGeneration, request = UUID()
        commandRequest = request; commandsLoading = true; commandsError = nil
        defer { if commandRequest == request { commandsLoading = false } }
        do {
            let result = try await connection.request("get_commands")
            guard metadataGeneration == generation, commandRequest == request else { return }
            commands = (result["commands"] as? [[String: Any]] ?? []).compactMap(PiCommand.init)
        } catch {
            guard metadataGeneration == generation, commandRequest == request else { return }
            commandsError = "命令列表刷新失败，可重试"
        }
    }
    func refreshLevels() async {
        if let result = try? await connection.request("get_available_thinking_levels") { thinkingLevels = result["levels"] as? [String] ?? ["off"] }
    }
    func refreshStats() async {
        guard let result = try? await connection.request("get_session_stats") else { return }
        applyStatistics(result)
    }
    private func applyStatistics(_ result: [String: Any]) {
        var pieces: [String] = []
        if let cost = result["cost"] as? Double { pieces.append(String(format: "$%.3f", cost)) }
        if let context = result["contextUsage"] as? [String: Any], let percent = context["percent"] as? Double { pieces.append(String(format: "上下文 %.0f%%", percent)) }
        statistics = pieces.joined(separator: " · ")
    }
    func setModel(_ model: PiModel) async {
        guard !busy else { return }
        do {
            _ = try await connection.request("set_model", ["provider": model.provider, "modelId": model.modelID])
            try await syncAll()
        } catch { self.error = error.localizedDescription }
    }
    func setThinking(_ level: String) async {
        do { _ = try await connection.request("set_thinking_level", ["level": level]); thinking = level }
        catch { self.error = error.localizedDescription }
    }
    func send() async {
        guard canSend else { return }
        let text = draft, images = attachments
        if text.hasPrefix("!"), images.isEmpty {
            guard !busy else { error = "请等待 Pi 当前运行结束后再执行 Bash 命令。"; return }
            let excluded = text.hasPrefix("!!")
            let command = String(text.dropFirst(excluded ? 2 : 1))
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            draft = ""; busy = true; bashRunning = true; status = "正在运行 Bash…"; runGeneration = UUID()
            bashMessageIndex = messages.count
            messages.append(.from(["role": "bashExecution", "command": command, "output": ""], index: messages.count))
            do { _ = try await connection.request("bash", ["command": command, "excludeFromContext": excluded], timeout: 3600) }
            catch { self.error = error.localizedDescription; if draft.isEmpty { draft = text } }
            busy = false; bashRunning = false; bashMessageIndex = nil; await refreshStateAfterRun(); return
        }
        // Built-in interactive commands belong to the original TUI; never send them as model prompts.
        let name = String(text.split(whereSeparator: { $0.isWhitespace }).first ?? "")
        if PiInteractiveCommands.names.contains(name), !commands.contains(where: { "/" + $0.name == name }) {
            error = "\(name) 请在右上角「Pi CLI」中运行。原生交互命令不经由 RPC 发送给模型。"
            return
        }
        var payload: [String: Any] = ["message": text]
        if !images.isEmpty { payload["images"] = images.map(\.wire) }
        let alreadyBusy = busy
        if busy { payload["streamingBehavior"] = queueBehavior }
        else { busy = true; status = "Pi 正在运行…" }
        runGeneration = UUID()
        draft = ""; attachments = []
        do {
            let result = try await connection.request("prompt", payload, timeout: 86400)
            if result["disposition"] as? String == "handled" { await refreshStateAfterRun() }
        } catch {
            if !alreadyBusy { busy = false; status = "" }
            if draft.isEmpty { draft = text; attachments = images }
            self.error = error.localizedDescription
        }
    }
    func abort() async {
        do {
            if bashRunning { _ = try await connection.request("abort_bash"); return }
            let result = try await connection.request("clear_queue")
            let saved = (result["steering"] as? [String] ?? []) + (result["followUp"] as? [String] ?? [])
            if !saved.isEmpty { draft = ([draft] + saved).filter { !$0.isEmpty }.joined(separator: "\n\n") }
            _ = try await connection.request("abort", timeout: 60)
        } catch { self.error = error.localizedDescription }
    }
    func renameSession() {
        guard let path = sessionPath else { return }
        renameTarget = PiSession(path: path, title: sessionName, date: Date())
    }
    func requestRename(_ session:PiSession,in project:Project) async {
        if sessionPath != session.path || self.project != project {
            guard canSwitch else { status="当前任务继续运行，完成后可重命名其他会话。";return }
            await switchSession(session,in:project)
        }
        guard sessionPath == session.path else { return }
        renameTarget=PiSession(path:session.path,title:sessions[project.id]?.first(where:{$0.path == session.path})?.title ?? session.title,date:session.date)
    }
    func saveSessionName(_ name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PiError.message("请输入会话名称。") }
        guard let target = renameTarget, target.path == sessionPath, connected else {
            throw PiError.message("请先打开需要重命名的会话。")
        }
        _ = try await connection.request("set_session_name", ["name": name])
        sessionName = name
        if let id = project?.id, let index = sessions[id]?.firstIndex(where: { $0.path == target.path }) { sessions[id]?[index].title = name }
        renameTarget = nil
        Task { await refreshSessions() }
    }
    func openModelSettings() { settingsSection = "models"; showSettings = true }
    var agentDirectory: URL {
        let path = environment?.variables["PI_CODING_AGENT_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent").path
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    // MARK: - 会话分支与维护（全部走官方 RPC）

    struct ForkPoint: Identifiable {
        let entryId: String
        let text: String
        var id: String { entryId }
        var display: String { text.replacingOccurrences(of: "\n", with: " ").prefix(80).description }
    }

    /// 从历史用户消息创建分支（/fork）。
    func forkFrom(_ point: ForkPoint) async {
        guard !busy else { status = "当前任务继续运行；完成或手动中止后可切换会话。"; return }
        do {
            let result = try await connection.request("fork", ["entryId": point.entryId], timeout: 120)
            if result["cancelled"] as? Bool == true { status = "Pi Extension 取消了分支。"; return }
            try await syncAll(); await refreshSessions()
            status = "已从所选消息创建分支。"
        } catch { self.error = error.localizedDescription }
    }

    /// 打开 fork 选择弹窗：列出当前分支全部用户消息。
    func showForkPicker() {
        guard connected, !connecting else { return }
        Task {
            do {
                let result = try await connection.request("get_fork_messages")
                let list = result["messages"] as? [[String: Any]] ?? []
                forkPoints = list.compactMap { item in
                    guard let id = item["entryId"] as? String, let text = item["text"] as? String else { return nil }
                    return ForkPoint(entryId: id, text: text)
                }
                forkSheetVisible = true
            } catch { self.error = error.localizedDescription }
        }
    }

    /// 克隆当前分支为新会话（/clone）。
    func cloneSession() async {
        guard !busy else { status = "当前任务继续运行；完成或手动中止后可切换会话。"; return }
        do {
            let result = try await connection.request("clone", [:], timeout: 120)
            if result["cancelled"] as? Bool == true { status = "Pi Extension 取消了克隆。"; return }
            try await syncAll(); await refreshSessions()
            status = "已克隆为新会话。"
        } catch { self.error = error.localizedDescription }
    }

    /// 手动压缩上下文（/compact）。
    func compactContext(instructions: String?) async {
        guard connected else { return }
        do {
            busy = true; status = "Pi 正在压缩上下文…"
            var fields: [String: Any] = [:]
            if let instructions, !instructions.isEmpty { fields["customInstructions"] = instructions }
            let result = try await connection.request("compact", fields, timeout: 600)
            let before = result["tokensBefore"] as? Int ?? 0
            let after = result["estimatedTokensAfter"] as? Int ?? 0
            status = "压缩完成：约 \(before) → \(after) tokens"
            try await syncAll()
        } catch { self.error = error.localizedDescription; busy = false }
    }

    /// 导出会话为 HTML。
    func exportSession() async {
        guard connected else { return }
        do {
            let result = try await connection.request("export_html", [:], timeout: 60)
            if let path = result["path"] as? String {
                status = "已导出到 \(path)"
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        } catch { self.error = error.localizedDescription }
    }

    func setQueueBehavior(_ mode: String) {
        queueBehavior = mode
        Task { _ = try? await connection.request(mode == "steer" ? "set_steering_mode" : "set_follow_up_mode", mode == "steer" ? ["mode": "all"] : ["mode": "one-at-a-time"]) }
    }

    func toggleAutoCompaction() async {
        autoCompaction.toggle()
        _ = try? await connection.request("set_auto_compaction", ["enabled": autoCompaction])
    }

    func toggleAutoRetry() async {
        autoRetry.toggle()
        _ = try? await connection.request("set_auto_retry", ["enabled": autoRetry])
    }
    func attachImages() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let data = try Data(contentsOf: url)
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
                attachments.append(ImageAttachment(name: url.lastPathComponent, data: data, mime: mime))
            } catch { self.error = error.localizedDescription }
        }
    }
    func replyDialog(_ dialog: ExtensionDialog, value: String? = nil, confirmed: Bool? = nil) {
        var response: [String: Any] = ["type": "extension_ui_response", "id": dialog.id]
        if let value { response["value"] = value }
        else if let confirmed { response["confirmed"] = confirmed }
        else { response["cancelled"] = true }
        do { try connection.send(response) } catch { self.error = error.localizedDescription }
        dialogs.removeAll { $0.id == dialog.id }
    }
    private func event(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        switch type {
        case "agent_start": runGeneration = UUID(); busy = true; status = "Pi 正在运行…"
        case "agent_settled": busy = false; status = ""; Task { await refreshStateAfterRun() }
        case "agent_end":
            // Older Pi versions lack agent_settled. get_state is authoritative and does not invent run behavior.
            Task { await refreshStateAfterRun() }
        case "message_start":
            guard let raw = event["message"] as? [String: Any] else { return }
            messages.append(.from(raw, index: messages.count))
            if raw["role"] as? String == "assistant" { streamingIndex = messages.count - 1 }
        case "message_update":
            guard let update = event["assistantMessageEvent"] as? [String: Any], let index = streamingIndex, messages.indices.contains(index) else { return }
            var blocks = messages[index].raw["content"] as? [[String: Any]] ?? []
            let blockIndex = update["contentIndex"] as? Int ?? 0
            while blocks.count <= blockIndex { blocks.append([:]) }
            let updateType = update["type"] as? String ?? ""
            if ["text_delta", "thinking_delta"].contains(updateType) {
                let key = updateType == "text_delta" ? "text" : "thinking"
                blocks[blockIndex]["type"] = key
                blocks[blockIndex][key] = (blocks[blockIndex][key] as? String ?? "") + (update["delta"] as? String ?? "")
            } else if ["text_end", "thinking_end"].contains(updateType) {
                let key = updateType == "text_end" ? "text" : "thinking"
                blocks[blockIndex] = ["type": key, key: update["content"] as? String ?? ""]
            } else if updateType == "toolcall_end", let tool = update["toolCall"] as? [String: Any] { blocks[blockIndex] = tool }
            messages[index].raw["content"] = blocks
        case "message_end":
            guard let raw = event["message"] as? [String: Any] else { return }
            if raw["role"] as? String == "assistant", let index = streamingIndex, messages.indices.contains(index) {
                messages[index].raw = raw; streamingIndex = nil
            }
            if let message = raw["errorMessage"] as? String { error = message }
        case "bash_execution_update":
            if let index = bashMessageIndex, messages.indices.contains(index) {
                let output = (messages[index].raw["output"] as? String ?? "") + (event["delta"] as? String ?? "")
                messages[index].raw["output"] = String(output.suffix(200000))
            }
        case "extension_error": error = event["error"] as? String ?? "Pi Extension 发生错误。"
        case "tool_execution_start": status = "正在运行 \(event["toolName"] as? String ?? "工具")…"
        case "tool_execution_end": status = "Pi 正在运行…"
        case "queue_update": pendingCount = (event["steering"] as? [Any] ?? []).count + (event["followUp"] as? [Any] ?? []).count
        case "thinking_level_changed": thinking = event["level"] as? String ?? thinking
        case "session_info_changed": sessionName = event["name"] as? String ?? "未命名会话"
        case "compaction_start", "auto_compaction_start": busy = true; status = "Pi 正在压缩上下文…"
        case "compaction_end", "auto_compaction_end":
            if let message = event["errorMessage"] as? String { error = message }
        case "auto_retry_start": status = "Pi 正在重试…"
        case "extension_ui_request": handleExtension(event)
        default: break
        }
    }
    private func refreshStateAfterRun() async {
        guard terminal == nil, connection.running, !connecting else { return }
        let generation = runGeneration
        do {
            let state = try await connection.request("get_state")
            guard generation == runGeneration, terminal == nil, !connecting else { return }
            busy = state["isStreaming"] as? Bool ?? false
            sessionPath = state["sessionFile"] as? String
            if let name = state["sessionName"] as? String { sessionName = name }
            if !busy {
                let history = try await connection.request("get_messages")
                guard generation == runGeneration, !busy, terminal == nil, !connecting else { return }
                messages = (history["messages"] as? [[String: Any]] ?? []).enumerated().map { .from($0.element, index: $0.offset) }
                streamingIndex = nil; status = ""; await refreshStats(); await refreshSessions()
                if sessionName == "新会话", let path = sessionPath, let item = sessions[project?.id ?? ""]?.first(where: { $0.path == path }) { sessionName = item.title }
            }
        } catch { if !connecting { self.error = error.localizedDescription } }
    }
    private func handleExtension(_ event: [String: Any]) {
        guard let method = event["method"] as? String, let id = event["id"] as? String else { return }
        switch method {
        case "select", "confirm", "input", "editor":
            dialogs.append(ExtensionDialog(id: id, method: method, title: event["title"] as? String ?? "Pi Extension", message: event["message"] as? String ?? "", options: event["options"] as? [String] ?? [], placeholder: event["placeholder"] as? String ?? "", prefill: event["prefill"] as? String ?? ""))
            if let milliseconds = event["timeout"] as? Double {
                Task { try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds) * 1_000_000)); dialogs.removeAll { $0.id == id } }
            }
        case "notify": status = event["message"] as? String ?? ""
        case "setStatus": if let key = event["statusKey"] as? String { extensionStatus[key] = event["statusText"] as? String }
        case "setWidget": if let key = event["widgetKey"] as? String { widgets[key] = event["widgetLines"] as? [String] }
        case "setTitle": if let title = event["title"] as? String { NSApp.mainWindow?.title = title }
        case "set_editor_text": draft = event["text"] as? String ?? ""
        default: break
        }
    }
    func openTerminal() async {
        guard canSwitch, let project, let environment else { return }
        saveDraft()
        metadataGeneration = UUID(); metadataTask?.cancel()
        connecting = true
        await connection.stop(); connected = false
        let session = TerminalSession(environment: environment, cwd: project.path, session: sessionPath, sessionDirectory: sessionDirectory)
        terminal = session; connecting = false
        session.onExit = { [weak self] in
            guard let self else { return }
            self.terminal = nil
            Task { await self.selectProject(project) }
        }
    }
    func saveSettings() async {
        UserDefaults.standard.set(executableOverride, forKey: "piExecutable")
        UserDefaults.standard.set(sessionDirectory, forKey: "sessionDirectory")
        PiEnvironment.invalidate(override:executableOverride)
        showSettings = false
        status = busy ? "设置已保存，当前任务继续运行；连接配置下次生效。" : "设置已保存，下次连接时生效。"
    }
    func shutdown() async {
        shuttingDown = true; refreshTimer?.invalidate(); metadataTask?.cancel(); runActivity.update(running: false)
        if let terminal { await terminal.stop() }
        await connection.stop()
    }
}
