import Cocoa
import CoreAudio
import AudioToolbox

// MARK: - helpers
let debug = CommandLine.arguments.contains("--debug")
func log(_ s: String) {
    guard debug else { return }
    let line = "\(Date()) \(s)\n"
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "SystemSoundPan.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

func getProp<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v = initial
    var s = UInt32(MemoryLayout<T>.size)
    AudioObjectGetPropertyData(obj, &a, 0, nil, &s, &v)
    return v
}

/// 対象にするプロセス(バンドルID)。システム音を鳴らすデーモン。
let targetBundleIDs: Set<String> = ["systemsoundserverd"]

/// 「ブラウザの音もパンする」がオンのときに対象に加える、ブラウザのバンドルID(の先頭部分)
let browserPrefixes = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox", "com.apple.Safari", "com.apple.WebKit"]
func isBrowserBundleID(_ id: String) -> Bool { browserPrefixes.contains { id.hasPrefix($0) } }

var browserMode = UserDefaults.standard.bool(forKey: "browserMode")
/// 現在タップしているブラウザ側のオーディオプロセス
var browserObjectIDs: [AudioObjectID] = []

func targetProcessObjects() -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    return ids.filter { id in
        let cf: Unmanaged<CFString>? = getProp(id, kAudioProcessPropertyBundleID, nil as Unmanaged<CFString>?)
        guard let s = cf?.takeRetainedValue() as String? else { return false }
        if targetBundleIDs.contains(s) { return true }
        return browserMode && isBrowserBundleID(s)
    }
}

func isBrowserObject(_ id: AudioObjectID) -> Bool {
    let cf: Unmanaged<CFString>? = getProp(id, kAudioProcessPropertyBundleID, nil as Unmanaged<CFString>?)
    guard let s = cf?.takeRetainedValue() as String? else { return false }
    return isBrowserBundleID(s)
}

func browserAudioPlaying() -> Bool {
    browserObjectIDs.contains { (getProp($0, kAudioProcessPropertyIsRunningOutput, UInt32(0)) as UInt32) != 0 }
}

func defaultOutputUID() -> String? {
    let dev: AudioObjectID = getProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
    guard dev != 0 else { return nil }
    let cf: Unmanaged<CFString>? = getProp(dev, kAudioDevicePropertyDeviceUID, nil as Unmanaged<CFString>?)
    return cf?.takeRetainedValue() as String?
}

// MARK: - pan (window position)
/// パンの強調倍率(1.0で画面位置そのまま、大きいほど極端に振れる)
var panGain: CGFloat = {
    let v = UserDefaults.standard.double(forKey: "panGain")
    return v > 0 ? CGFloat(v) : 2.0
}()

final class PanState {
    var calls = 0; var inPeak: Float = 0; var info = ""
    // 書き込みはメインスレッド、読み出しはIOスレッド。Float単体なので実用上問題なし。
    var left: Float = 1
    var right: Float = 1
    var peak: Float = 0
}
let panState = PanState()

/// 指定PIDの最前面の通常ウィンドウについて、画面全体に対する中心位置(-1...1)を返す
func panPosition(forPID pid: pid_t) -> Float? { panPosition(matching: { $0 == pid }) }

/// 条件に合うプロセスの、最前面の通常ウィンドウの位置(-1...1)
func panPosition(matching match: (pid_t) -> Bool) -> Float? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    // 前面から順に並んでいるので、そのアプリの最初の通常ウィンドウを使う
    for w in infos {
        guard let wpid = w[kCGWindowOwnerPID as String] as? Int32, match(wpid),
              (w[kCGWindowLayer as String] as? Int) == 0,
              let bd = w[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bd["X"], let width = bd["Width"], width > 50 else { continue }
        let screens = NSScreen.screens
        guard let minX = screens.map({ $0.frame.minX }).min(), let maxX = screens.map({ $0.frame.maxX }).max(), maxX > minX else { return nil }
        let cx = x + width / 2
        return Float(max(-1, min(1, ((cx - minX) / (maxX - minX) * 2 - 1) * panGain)))
    }
    return nil
}

// MARK: - notification source (which app triggered the notification sound)
/// 通知音を鳴らしたアプリ(バンドルID)と、その有効期限
var notificationSource: (bundleID: String, until: Date)?
/// システム音を要求したプロセス(PID)と、その有効期限
var requesterSource: (pid: pid_t, until: Date)?

final class NotificationWatcher {
    var proc: Process?
    var buffer = Data()

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--predicate",
                       "(process == \"NotificationCenter\" AND eventMessage CONTAINS \"Playing notification sound\") OR (process == \"systemsoundserverd\" AND eventMessage CONTAINS \"Incoming Request\")"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData
            if d.isEmpty { return }
            self.buffer.append(d)
            while let nl = self.buffer.firstIndex(of: 10) {
                let line = String(decoding: self.buffer[..<nl], as: UTF8.self)
                self.buffer.removeSubrange(...nl)
                self.handle(line)
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.start() }
        }
        do { try p.run(); proc = p } catch { log("log stream failed: \(error)") }
    }

    func handle(_ line: String) {
        // systemsoundserverd: "... Incoming Request : actionID 4100, inClientPID 936(NotificationCent), ..."
        if let r = line.range(of: "inClientPID ") {
            let digits = line[r.upperBound...].prefix(while: { $0.isNumber })
            if let pid = pid_t(digits) {
                log("sound requested by pid \(pid) \(line[r.upperBound...].dropFirst(digits.count).prefix(20))")
                DispatchQueue.main.async { requesterSource = (pid, Date().addingTimeInterval(2.5)) }
            }
            return
        }
        // 例: "... Playing notification sound {  } for com.apple.MobileSMS"
        guard let r = line.range(of: " for ", options: .backwards) else { return }
        let id = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !id.contains(" ") else { return }
        log("notification sound from \(id)")
        DispatchQueue.main.async { notificationSource = (id, Date().addingTimeInterval(2.5)) }
    }

    func stop() {
        proc?.terminationHandler = nil
        proc?.terminate()
        proc = nil
    }
}

func updatePan() {
    var pan: Float?
    // 通知音の直後は、通知を出したアプリのウィンドウ位置を基準にする(見えていなければ最前面に戻す)
    if let src = requesterSource, src.until > Date() {
        // 音を要求したプロセス自身(または、そのアプリ)のウィンドウ
        var pids = [src.pid]
        if let app = NSRunningApplication(processIdentifier: src.pid), let bid = app.bundleIdentifier {
            pids += NSRunningApplication.runningApplications(withBundleIdentifier: bid).map { $0.processIdentifier }
        }
        for pid in pids { if let p = panPosition(forPID: pid) { pan = p; break } }
    }
    if pan == nil, let src = notificationSource, src.until > Date() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: src.bundleID) {
            if let p = panPosition(forPID: app.processIdentifier) { pan = p; break }
        }
    }
    // ブラウザの音が鳴っているときは、ブラウザのウィンドウ位置を基準にする
    if pan == nil, browserMode, browserAudioPlaying() {
        pan = panPosition(matching: { pid in
            guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
            return isBrowserBundleID(id)
        })
    }
    if pan == nil, let app = NSWorkspace.shared.frontmostApplication {
        pan = panPosition(forPID: app.processIdentifier)
    }
    guard let pan else { return }
    panState.left = min(1, 1 - pan)
    panState.right = min(1, 1 + pan)
}

// MARK: - tap engine
final class TapEngine {
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    var activeObjects: [AudioObjectID] = []
    var activeOutputUID: String?
    var running: Bool { procID != nil }

    func start(objects: [AudioObjectID], outputUID: String) -> Bool {
        let desc = CATapDescription(stereoMixdownOfProcesses: objects)
        desc.uuid = UUID()
        desc.name = "SystemSoundPan"
        desc.muteBehavior = .muted
        desc.isPrivate = true
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { log("CreateProcessTap failed \(st)"); return false }

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SystemSoundPan",
            kAudioAggregateDeviceUIDKey: "SystemSoundPan-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard st == noErr else { log("CreateAggregate failed \(st)"); stop(); return false }

        let state = panState
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            let outList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: outData))
            state.calls += 1; state.info = "in=\(inList.count) out=\(outList.count) inCh=\(inList.count > 0 ? inList[0].mNumberChannels : 0) inBytes=\(inList.count > 0 ? inList[0].mDataByteSize : 0)"
            for b in outList { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
            guard inList.count > 0, outList.count > 0 else { return }

            // 入力(タップ)から L/R を取り出す
            var inL: UnsafeMutablePointer<Float>?, inR: UnsafeMutablePointer<Float>?
            var inStride = 1, frames = 0
            let b0 = inList[inList.count - 1]  // タップは最後の入力バッファ
            guard let d0 = b0.mData?.assumingMemoryBound(to: Float.self) else { return }
            if b0.mNumberChannels >= 2 {
                inL = d0; inR = d0 + 1; inStride = Int(b0.mNumberChannels)
                frames = Int(b0.mDataByteSize) / (4 * inStride)
            } else if inList.count >= 2, let d1 = inList[inList.count - 1].mData?.assumingMemoryBound(to: Float.self) {
                inL = d0; inR = d1; inStride = 1
                frames = Int(b0.mDataByteSize) / 4
            } else {
                inL = d0; inR = d0; inStride = 1
                frames = Int(b0.mDataByteSize) / 4
            }
            guard let l = inL, let r = inR else { return }
            _ = "in=\(inList.count)x\(b0.mNumberChannels) frames=\(frames) out=\(outList.count)x\(outList[0].mNumberChannels)"
            for i in 0..<frames { state.inPeak = max(state.inPeak, abs(l[i * inStride])) }
            let gl = state.left, gr = state.right
            var peak: Float = 0

            let o0 = outList[0]
            guard let od0 = o0.mData?.assumingMemoryBound(to: Float.self) else { return }
            if o0.mNumberChannels >= 2 {
                let oc = Int(o0.mNumberChannels)
                let n = min(frames, Int(o0.mDataByteSize) / (4 * oc))
                for i in 0..<n {
                    let a = l[i * inStride] * gl, c = r[i * inStride] * gr
                    od0[i * oc] = a; od0[i * oc + 1] = c
                    peak = max(peak, abs(a), abs(c))
                }
            } else if outList.count >= 2, let od1 = outList[1].mData?.assumingMemoryBound(to: Float.self) {
                let n = min(frames, Int(o0.mDataByteSize) / 4)
                for i in 0..<n {
                    let a = l[i * inStride] * gl, c = r[i * inStride] * gr
                    od0[i] = a; od1[i] = c
                    peak = max(peak, abs(a), abs(c))
                }
            } else {
                let n = min(frames, Int(o0.mDataByteSize) / 4)
                for i in 0..<n { od0[i] = (l[i * inStride] * gl + r[i * inStride] * gr) * 0.5 }
            }
            if peak > state.peak { state.peak = peak }
        }
        guard st == noErr, let pid = procID else { log("IOProc failed \(st)"); stop(); return false }
        st = AudioDeviceStart(aggID, pid)
        guard st == noErr else { log("DeviceStart failed \(st)"); stop(); return false }
        activeObjects = objects
        activeOutputUID = outputUID
        log("started tap on \(objects) -> \(outputUID)")
        return true
    }

    func stop() {
        if let pid = procID { AudioDeviceStop(aggID, pid); AudioDeviceDestroyIOProcID(aggID, pid); procID = nil }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
        activeObjects = []
        activeOutputUID = nil
    }
}

// MARK: - app
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = TapEngine()
    let watcher = NotificationWatcher()
    var item: NSStatusItem!
    var enabled = true
    var starting = false
    let engineQueue = DispatchQueue(label: "engine")
    var toggle: NSMenuItem!
    var browserItem: NSMenuItem!
    var gainItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◐"
        let menu = NSMenu()
        toggle = NSMenuItem(title: "システム音をウィンドウ位置でパン", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self; toggle.state = .on
        menu.addItem(toggle)
        browserItem = NSMenuItem(title: "ブラウザの音もパンする(動画も振れます)", action: #selector(toggleBrowser), keyEquivalent: "")
        browserItem.target = self; browserItem.state = browserMode ? .on : .off
        menu.addItem(browserItem)
        gainItem = NSMenuItem(title: "", action: #selector(editGain), keyEquivalent: "")
        gainItem.target = self
        updateGainTitle()
        menu.addItem(gainItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in updatePan() }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.reconcile() }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in log("calls=\(panState.calls) inPeak=\(panState.inPeak) \(panState.info)") }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            if panState.peak > 0.001 {
                log(String(format: "sound peak=%.3f L=%.2f R=%.2f", panState.peak, panState.left, panState.right))
                panState.peak = 0
            }
        }
        reconcile()
        watcher.start()
    }

    @objc func toggleEnabled() {
        enabled.toggle()
        toggle.state = enabled ? .on : .off
        item.button?.title = enabled ? "◐" : "○"
        reconcile()
    }

    func updateGainTitle() { gainItem.title = String(format: "パンの倍率… (現在 %.1f)", Double(panGain)) }

    @objc func editGain() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "パンの倍率"
        alert.informativeText = "1.0 = 画面上の位置のとおり / 大きいほど極端に振れます(0.1〜10)。初期値は 2.0 です。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = String(format: "%.1f", Double(panGain))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let v = Double(text), v >= 0.1, v <= 10 {
            panGain = CGFloat(v)
            UserDefaults.standard.set(v, forKey: "panGain")
            updateGainTitle()
        } else {
            let e = NSAlert(); e.messageText = "0.1〜10 の数値を入力してください"; e.runModal()
        }
    }

    @objc func toggleBrowser() {
        browserMode.toggle()
        UserDefaults.standard.set(browserMode, forKey: "browserMode")
        browserItem.state = browserMode ? .on : .off
        log("browserMode = \(browserMode)")
        reconcile()
    }

    func reconcile() {
        guard enabled else { if engine.running { engineQueue.async { self.engine.stop() } }; return }
        let objs = targetProcessObjects()
        browserObjectIDs = browserMode ? objs.filter { isBrowserObject($0) } : []
        let uid = defaultOutputUID()
        log("reconcile objs=\(objs) uid=\(uid ?? "nil") running=\(engine.running)")
        guard let uid, !objs.isEmpty else { if engine.running { log("target gone"); engineQueue.async { self.engine.stop() } }; return }
        if starting { return }
        if engine.running && engine.activeObjects == objs && engine.activeOutputUID == uid { return }
        if starting { return }
        starting = true
        engineQueue.async { [self] in
            engine.stop()
            let ok = engine.start(objects: objs, outputUID: uid)
            log("start result \(ok)")
            DispatchQueue.main.async { self.starting = false }
        }
    }

    func applicationWillTerminate(_ n: Notification) { watcher.stop(); engine.stop() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
var signalSources: [DispatchSourceSignal] = []
// Ctrl-C / kill でもタップを解除してシステム音を元に戻す
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { delegate.watcher.stop(); exit(0) }
    src.resume()
    signalSources.append(src)
}
app.run()

