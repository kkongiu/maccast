import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

// Configurazione iniettata dal bundle (build.sh).
let PROJECT_DIR: String =
    (Bundle.main.object(forInfoDictionaryKey: "MaccastProjectDir") as? String)
    ?? "\(NSHomeDirectory())/projects/maccast"
let PYTHON = "/usr/bin/python3"
let API_BASE = URL(string: "http://127.0.0.1:8770")!
let STREAM_PORT = 5100

// MARK: - Modelli

struct Device: Identifiable, Decodable {
    var id: String { name }
    let index: Int
    let name: String
    let type: String
}

struct HistoryItem: Identifiable, Decodable {
    var id: String { kind + "|" + value }
    let kind: String
    let value: String
    let label: String
}

struct DLNADevice: Identifiable, Decodable {
    var id: String { av_control ?? name }
    let name: String
    let ip: String
    let av_control: String?
}

func stripANSI(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m",
                           with: "", options: .regularExpression)
}

// MARK: - Modello applicativo

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var selectedDevice: String = ""
    @Published var resolution: String = "1080p"
    @Published var ytURL: String = ""
    @Published var srcURL: String = ""
    @Published var filePath: String = ""
    @Published var history: [HistoryItem] = []
    @Published var log: [String] = []
    @Published var running: Bool = false
    @Published var kind: String?
    @Published var message: String?
    @Published var serverStarting: Bool = false
    @Published var target: String = "cast"
    @Published var dlnaDevices: [DLNADevice] = []
    @Published var selectedDLNA: Int = 0
    @Published var vidaaDevices: [String] = []
    @Published var selectedVidaa: String = ""
    @Published var vidaaHost: String = ""
    @Published var apps: [String] = []
    @Published var selectedApp: String = ""

    private var serverProc: Process?
    private var didStartServer = false
    private var timer: Timer?

    init() {
        Task { await self.boot() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { await self.poll() }
        }
    }

    // MARK: Backend

    private func boot() async {
        if await isUp() {
            await refreshAll()
            return
        }
        serverStarting = true
        startServer()
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await isUp() { break }
        }
        serverStarting = false
        await refreshAll()
    }

    private func isUp() async -> Bool {
        guard let j = await getJSON("/api/status") else { return false }
        return (j["ok"] as? Bool) == true
    }

    private func startServer() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: PYTHON)
        proc.arguments = ["-u", "\(PROJECT_DIR)/webui.py"]
        var env = ProcessInfo.processInfo.environment
        env["MACCast_NO_BROWSER"] = "1"
        let extra = "\(NSHomeDirectory())/Library/Python/3.9/bin:/opt/homebrew/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "")
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: PROJECT_DIR)
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            serverProc = proc
            didStartServer = true
        } catch {
            show("Impossibile avviare il backend: \(error.localizedDescription)")
        }
    }

    func shutdown() {
        timer?.invalidate()
        if didStartServer, let p = serverProc, p.isRunning {
            p.terminate()
        }
    }

    // MARK: HTTP

    private func getJSON(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: path, relativeTo: API_BASE) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func postJSON(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        guard let url = URL(string: path, relativeTo: API_BASE) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    // MARK: Azioni

    func refreshAll() async {
        await refreshDevices()
        await refreshHistory()
        await refreshDLNA()
        await refreshVidaa()
    }

    func refreshDLNA() async {
        guard let j = await getJSON("/api/dlna/devices"),
              (j["ok"] as? Bool) == true,
              let arr = j["devices"] as? [[String: Any]] else { return }
        dlnaDevices = arr.map { d in
            DLNADevice(name: d["name"] as? String ?? "DLNA",
                       ip: d["ip"] as? String ?? "",
                       av_control: d["av_control"] as? String)
        }
        if selectedDLNA >= dlnaDevices.count { selectedDLNA = 0 }
    }

    // MARK: VIDAA (Hisense)

    func refreshVidaa() async {
        guard let j = await getJSON("/api/vidaa/devices"),
              (j["ok"] as? Bool) == true else { return }
        vidaaDevices = (j["devices"] as? [String]) ?? []
        if let h = j["host"] as? String, !h.isEmpty {
            vidaaHost = h
            if selectedVidaa.isEmpty { selectedVidaa = h }
        }
        if selectedVidaa.isEmpty, let first = vidaaDevices.first {
            selectedVidaa = first
        }
    }

    func connectVidaa() async {
        guard !selectedVidaa.isEmpty else {
            show("Seleziona un dispositivo")
            return
        }
        guard let j = await postJSON("/api/vidaa/set",
                                     ["host": selectedVidaa]) else {
            show("Backend non raggiungibile")
            return
        }
        if (j["ok"] as? Bool) == true {
            vidaaHost = selectedVidaa
            show("Connesso a \(selectedVidaa)")
            await loadApps()
        } else {
            show(j["error"] as? String ?? "Connessione fallita")
        }
    }

    func loadApps() async {
        guard let j = await getJSON("/api/vidaa/apps"),
              (j["ok"] as? Bool) == true,
              let arr = j["result"] as? [String] else { return }
        apps = arr
        if selectedApp.isEmpty, let first = apps.first { selectedApp = first }
    }

    func launchApp() async {
        guard !selectedApp.isEmpty else { return }
        _ = await postJSON("/api/vidaa/launch", ["name": selectedApp])
        show("Apro \(selectedApp)…")
    }

    func sendKey(_ key: String) async {
        _ = await postJSON("/api/vidaa/key", ["key": key])
    }

    func vidaaVolume(_ action: String, value: Int? = nil) async {
        var body: [String: Any] = ["action": action]
        if let v = value { body["value"] = v }
        _ = await postJSON("/api/vidaa/volume", body)
    }

    func vidaaSource(_ source: String) async {
        _ = await postJSON("/api/vidaa/source", ["source": source])
        show("Sorgente: \(source)")
    }

    func refreshDevices() async {
        guard let j = await getJSON("/api/devices"),
              (j["ok"] as? Bool) == true,
              let arr = j["devices"] as? [[String: Any]] else { return }
        devices = arr.compactMap { d in
            guard let name = d["name"] as? String else { return nil }
            return Device(index: d["index"] as? Int ?? 0,
                          name: name,
                          type: d["type"] as? String ?? "")
        }
    }

    func refreshHistory() async {
        guard let j = await getJSON("/api/history"),
              (j["ok"] as? Bool) == true,
              let arr = j["items"] as? [[String: Any]] else { return }
        history = arr.compactMap { it in
            guard let v = it["value"] as? String else { return nil }
            return HistoryItem(kind: it["kind"] as? String ?? "",
                               value: v,
                               label: it["label"] as? String ?? v)
        }
    }

    private func poll() async {
        guard let j = await getJSON("/api/status"),
              (j["ok"] as? Bool) == true else { return }
        running = j["running"] as? Bool ?? false
        kind = j["kind"] as? String
        if let arr = j["log"] as? [String] {
            log = arr.map(stripANSI)
        }
    }

    func cast(kind k: String, extra: [String: Any]) async {
        if target == "dlna" {
            var body: [String: Any] = ["kind": k, "index": selectedDLNA]
            if k == "sourceurl" { body["kind"] = "url" }
            for (key, value) in extra { body[key] = value }
            guard let j = await postJSON("/api/dlna/cast", body) else {
                show("Backend non raggiungibile")
                return
            }
            if (j["ok"] as? Bool) != true {
                show(j["error"] as? String ?? "Errore")
            } else {
                show("Trasmissione DLNA avviata")
            }
            return
        }
        var body: [String: Any] = [
            "kind": k,
            "device": selectedDevice,
            "resolution": resolution,
        ]
        for (key, value) in extra { body[key] = value }
        guard let j = await postJSON("/api/cast", body) else {
            show("Backend non raggiungibile")
            return
        }
        if (j["ok"] as? Bool) != true {
            show(j["error"] as? String ?? "Errore")
        } else {
            show("Trasmissione avviata")
            await refreshHistory()
        }
    }

    func stop() async {
        if target == "dlna" {
            _ = await postJSON("/api/dlna/stop", [:])
        } else {
            _ = await postJSON("/api/stop", [:])
        }
        show("Trasmissione fermata")
    }

    func clearHistory() async {
        _ = await postJSON("/api/history/clear", [:])
        await refreshHistory()
    }

    func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audiovisualContent, .movie, .video, .audio]
        if panel.runModal() == .OK, let url = panel.url {
            filePath = url.path
        }
    }

    func show(_ text: String) {
        message = text
        let current = text
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.message == current { self.message = nil }
        }
    }
}

// MARK: - Ciclo di vita

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}

@main
struct MaccastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Maccast") {
            ContentView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Componenti UI

struct Card<Content: View>: View {
    let icon: String
    let title: String
    let trailing: AnyView
    let content: Content

    init(icon: String, title: String, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.trailing = AnyView(EmptyView())
        self.content = content()
    }

    init<T: View>(icon: String, title: String,
                  @ViewBuilder trailing: () -> T,
                  @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.trailing = AnyView(trailing())
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        LinearGradient(
                            colors: [Color.accentColor,
                                     Color.accentColor.opacity(0.72)],
                            startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title).font(.headline)
                Spacer()
                trailing
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 5, y: 1)
    }
}

// MARK: - Vista

struct ContentView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    deviceCard
                    if m.target == "vidaa" {
                        vidaaAppCard
                        vidaaRemoteCard
                    } else {
                        ytCard
                        srcCard
                        fileCard
                        screenCard
                        if !m.history.isEmpty { recentsCard }
                        logCard
                    }
                }
                .padding(16)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 660, idealWidth: 700, minHeight: 680, idealHeight: 800)
        .animation(.easeInOut(duration: 0.2), value: m.message)
        .animation(.easeInOut(duration: 0.25), value: m.running)
        .overlay(alignment: .bottom) { toast }
        .onChange(of: m.target) { value in
            Task {
                switch value {
                case "vidaa":
                    await m.refreshVidaa()
                    await m.loadApps()
                case "dlna":
                    await m.refreshDLNA()
                default:
                    await m.refreshDevices()
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.accentColor,
                                 Color.accentColor.opacity(0.68)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                Image(systemName: "airplayvideo")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Maccast").font(.title3).bold()
                Text(m.running ? "In trasmissione" : "Pronto")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            statusPill
            Button {
                Task { await m.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .help("Aggiorna dispositivi")
            .disabled(m.serverStarting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(m.running ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 8, height: 8)
                .shadow(color: m.running ? .green.opacity(0.6) : .clear, radius: 4)
            Text(m.running ? "LIVE" : "OFF")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(m.running ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background((m.running ? Color.green : Color.secondary).opacity(0.12),
                    in: Capsule())
    }

    // MARK: Card

    private var deviceCard: some View {
        Card(icon: "dot.radiowaves.left.and.right", title: "Dispositivo") {
            VStack(spacing: 10) {
                Picker("", selection: $m.target) {
                    Text("Google Cast").tag("cast")
                    Text("DLNA").tag("dlna")
                    Text("VIDAA").tag("vidaa")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if m.target == "cast" {
                    HStack(spacing: 12) {
                        Picker("", selection: $m.selectedDevice) {
                            Text("Primo disponibile").tag("")
                            ForEach(m.devices) { d in
                                Text("\(d.name)  ·  \(d.type)").tag(d.name)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)

                        Picker("", selection: $m.resolution) {
                            ForEach(["720p", "1080p", "1440p", "uhd"], id: \.self) {
                                Text($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                } else if m.target == "dlna" {
                    HStack(spacing: 12) {
                        Picker("", selection: $m.selectedDLNA) {
                            if m.dlnaDevices.isEmpty {
                                Text("Nessun dispositivo DLNA").tag(0)
                            }
                            ForEach(Array(m.dlnaDevices.enumerated()),
                                    id: \.offset) { idx, d in
                                Text("\(d.name)  ·  \(d.ip)").tag(idx)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        Button {
                            Task { await m.refreshDLNA() }
                        } label: {
                            Label("Cerca", systemImage: "magnifyingglass")
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        Picker("", selection: $m.selectedVidaa) {
                            if m.vidaaDevices.isEmpty {
                                Text("Nessun dispositivo").tag("")
                            }
                            ForEach(m.vidaaDevices, id: \.self) { ip in
                                Text(ip).tag(ip)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        Button {
                            Task { await m.refreshVidaa() }
                        } label: {
                            Label("Cerca", systemImage: "magnifyingglass")
                        }
                        Button {
                            Task { await m.connectVidaa() }
                        } label: {
                            Label("Connetti", systemImage: "link")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var vidaaAppCard: some View {
        Card(icon: "app.badge", title: "App") {
            HStack(spacing: 10) {
                Picker("", selection: $m.selectedApp) {
                    if m.apps.isEmpty { Text("Nessuna app").tag("") }
                    ForEach(m.apps, id: \.self) { Text($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Button {
                    Task { await m.loadApps() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Ricarica app")
                Button {
                    Task { await m.launchApp() }
                } label: {
                    Label("Apri", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(m.selectedApp.isEmpty)
            }
        }
    }

    private var vidaaRemoteCard: some View {
        Card(icon: "appletvremote.gen1", title: "Telecomando") {
            VStack(spacing: 10) {
                Button {
                    Task { await m.sendKey("KEY_UP") }
                } label: {
                    Image(systemName: "chevron.up")
                }
                HStack(spacing: 8) {
                    Button {
                        Task { await m.sendKey("KEY_LEFT") }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    Button("OK") {
                        Task { await m.sendKey("KEY_OK") }
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Task { await m.sendKey("KEY_RIGHT") }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                }
                Button {
                    Task { await m.sendKey("KEY_DOWN") }
                } label: {
                    Image(systemName: "chevron.down")
                }

                Divider()

                HStack(spacing: 8) {
                    Button { Task { await m.sendKey("KEY_BACK") } } label: {
                        Label("Indietro", systemImage: "arrow.uturn.backward")
                    }
                    Button { Task { await m.sendKey("KEY_HOME") } } label: {
                        Label("Home", systemImage: "house")
                    }
                    Button { Task { await m.sendKey("KEY_MENU") } } label: {
                        Label("Menu", systemImage: "line.3.horizontal")
                    }
                }

                HStack(spacing: 8) {
                    Button { Task { await m.sendKey("KEY_PLAY") } } label: {
                        Image(systemName: "play.fill")
                    }
                    Button { Task { await m.sendKey("KEY_PAUSE") } } label: {
                        Image(systemName: "pause.fill")
                    }
                    Button { Task { await m.sendKey("KEY_STOP") } } label: {
                        Image(systemName: "stop.fill")
                    }
                    Spacer()
                    Button { Task { await m.vidaaVolume("down") } } label: {
                        Image(systemName: "speaker.minus")
                    }
                    Button { Task { await m.vidaaVolume("mute") } } label: {
                        Image(systemName: "speaker.slash")
                    }
                    Button { Task { await m.vidaaVolume("up") } } label: {
                        Image(systemName: "speaker.plus")
                    }
                }

                HStack(spacing: 8) {
                    Button("TV") { Task { await m.vidaaSource("tv") } }
                    Button("HDMI1") { Task { await m.vidaaSource("hdmi1") } }
                    Button("HDMI2") { Task { await m.vidaaSource("hdmi2") } }
                    Spacer()
                    Button { Task { await m.sendKey("KEY_POWER") } } label: {
                        Image(systemName: "power")
                    }
                    .tint(.red)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var ytCard: some View {
        Card(icon: "play.rectangle", title: "Video da URL") {
            VStack(alignment: .leading, spacing: 8) {
                Text("YouTube, Vimeo, Dailymotion, testate… (via yt-dlp)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("https://www.youtube.com/watch?v=…", text: $m.ytURL)
                        .textFieldStyle(.roundedBorder)
                    castButton("youtube", value: $m.ytURL)
                }
            }
        }
    }

    private var srcCard: some View {
        Card(icon: "link", title: "URL media diretto") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Link diretto a un file (.mp4, .m3u8, .mpd, .mp3...).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("https://esempio.com/video.mp4", text: $m.srcURL)
                        .textFieldStyle(.roundedBorder)
                    castButton("sourceurl", value: $m.srcURL)
                }
            }
        }
    }

    private var fileCard: some View {
        Card(icon: "folder", title: "File locale") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Video sul Mac (mp4, mkv, mov...).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("/Users/tu/Video/mio_video.mp4", text: $m.filePath)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        m.pickFile()
                    } label: {
                        Label("Sfoglia", systemImage: "folder")
                    }
                    castButton("file", key: "path", value: $m.filePath)
                }
            }
        }
    }

    private var screenCard: some View {
        Card(icon: "display", title: "Schermo") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplica lo schermo del Mac sulla TV.")
                        .font(.callout)
                    Text(m.target == "dlna"
                         ? "Non supportato su DLNA: seleziona Google Cast."
                         : "Video-only: l'audio di sistema richiede BlackHole.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await m.cast(kind: "screencast", extra: [:]) }
                } label: {
                    Label("Trasmetti schermo", systemImage: "airplayvideo")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(m.target == "dlna")
            }
        }
    }

    private var recentsCard: some View {
        Card(icon: "clock.arrow.circlepath", title: "Recenti",
             trailing: {
                Button("Svuota") { Task { await m.clearHistory() } }
                    .buttonStyle(.link)
                    .font(.caption)
             }) {
            VStack(spacing: 6) {
                ForEach(m.history) { item in
                    HStack(spacing: 10) {
                        Text(prefix(for: item.kind))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12),
                                        in: Capsule())
                        Text(item.label)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.value)
                        Spacer()
                        Button("Usa") { use(item) }
                            .buttonStyle(.link)
                            .font(.caption)
                        Button {
                            use(item)
                            play(item)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Riproduci")
                    }
                }
            }
        }
    }

    private var logCard: some View {
        Card(icon: "terminal", title: "Log",
             trailing: {
                Button {
                    Task { await m.stop() }
                } label: {
                    Label("Ferma", systemImage: "stop.fill")
                }
                .tint(.red)
                .controlSize(.small)
                .disabled(!m.running)
             }) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        if m.log.isEmpty {
                            Text("Nessun output.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(m.log.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(logColor(line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 190)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.06)))
                .onChange(of: m.log.count) { count in
                    guard count > 0 else { return }
                    withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let msg = m.message {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(.tint)
                Text(msg)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Helper

    private func castButton(_ kind: String,
                            key: String = "url",
                            value: Binding<String>) -> some View {
        Button {
            Task { await m.cast(kind: kind, extra: [key: value.wrappedValue]) }
        } label: {
            Label("Trasmetti", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(value.wrappedValue.isEmpty)
    }

    private func logColor(_ line: String) -> Color {
        let l = line.lowercased()
        if l.contains("error") || l.contains("traceback")
            || l.contains("not found") {
            return .red
        }
        if l.contains("warning") || l.contains("deprecat") {
            return .orange
        }
        if l.contains("running on") || l.contains("cast media")
            || l.contains("using media type") || l.contains("[done]") {
            return .green
        }
        return Color(nsColor: .secondaryLabelColor)
    }

    private func prefix(for kind: String) -> String {
        switch kind {
        case "youtube": return "YouTube"
        case "file": return "File"
        case "sourceurl": return "URL"
        default: return kind
        }
    }

    private func use(_ item: HistoryItem) {
        switch item.kind {
        case "youtube": m.ytURL = item.value
        case "file": m.filePath = item.value
        case "sourceurl": m.srcURL = item.value
        default: break
        }
    }

    private func play(_ item: HistoryItem) {
        switch item.kind {
        case "youtube":
            Task { await m.cast(kind: "youtube", extra: ["url": item.value]) }
        case "file":
            Task { await m.cast(kind: "file", extra: ["path": item.value]) }
        case "sourceurl":
            Task { await m.cast(kind: "sourceurl", extra: ["url": item.value]) }
        default: break
        }
    }
}
