import Cocoa
import CoreAudio
import AudioToolbox

// MARK: - helpers
let debug = CommandLine.arguments.contains("--debug")
// 切り分け用(通常は使いません): 機能を1つずつ止めて起動できる
let noWindows = CommandLine.arguments.contains("--no-windows")   // ウィンドウ位置の取得を止める(パンは中央のまま)
let noWatcher = CommandLine.arguments.contains("--no-watcher")   // ログの監視(log stream)を止める
let noTap = CommandLine.arguments.contains("--no-tap")           // 音のタップを作らない(音は何も変わらない)
func log(_ s: @autoclosure () -> String) {  // デバッグ時以外は、文字列を組み立てない
    guard debug else { return }
    let line = "\(Date()) \(s())\n"
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

/// ユーザーが追加した「パン対象のアプリ」(アプリ自身が鳴らす音を対象にする)
struct ExtraApp: Codable { var id: String; var name: String; var on: Bool }
var extraApps: [ExtraApp] = {
    guard let d = UserDefaults.standard.data(forKey: "extraApps"),
          let a = try? JSONDecoder().decode([ExtraApp].self, from: d) else { return [] }
    return a
}()
func saveExtraApps() {
    if let d = try? JSONEncoder().encode(extraApps) { UserDefaults.standard.set(d, forKey: "extraApps") }
}
/// アプリ側のタップ(キーは "browser" または "app:<バンドルID>")。メインスレッドだけで触る
var appEngines: [String: TapEngine] = [:]

/// 追加アプリのうち、このバンドルIDに当たるもののキー("app:<ID>")
func extraKey(for bundleID: String) -> String? {
    guard let a = extraApps.first(where: { $0.on && (bundleID == $0.id || bundleID.hasPrefix($0.id + ".")) }) else { return nil }
    return "app:" + a.id
}

/// システム音のプロセスと、アプリ側のプロセスを、別々に返す。アプリ側は、ブラウザ("browser")と、追加アプリごと("app:<ID>")に分ける。
/// 別々のタップにすることで、それぞれが、自分のウィンドウ位置で左右に振れ、お互いのパンに引きずられない
func processObjects() -> (sys: [AudioObjectID], groups: [String: [AudioObjectID]]) {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    var sys: [AudioObjectID] = []
    var groups: [String: [AudioObjectID]] = [:]
    for id in ids {
        let cf: Unmanaged<CFString>? = getProp(id, kAudioProcessPropertyBundleID, nil as Unmanaged<CFString>?)
        guard let s = cf?.takeRetainedValue() as String? else { continue }
        if targetBundleIDs.contains(s) { sys.append(id) }
        else if let k = extraKey(for: s) { groups[k, default: []].append(id) }
        else if browserMode && isBrowserBundleID(s) { groups["browser", default: []].append(id) }
    }
    return (sys, groups)
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
    /// 入力に音が来た最後の時刻(省電力のための目安。書き込みはIOスレッド、読み出しはメインスレッド)
    var lastSound: CFAbsoluteTime = 0
}
/// システム音用のパンの状態(アプリ側は、タップごとに持つ)
let sysState = PanState()

/// PID → バンドルID の記録。NSRunningApplication の問い合わせは、システムとの通信が毎回発生して重いので、結果を覚えておく
var bundleIDCache: [pid_t: String?] = [:]
var bundleIDCacheClearedAt: CFAbsoluteTime = 0
func cachedBundleID(_ pid: pid_t) -> String? {
    let now = CFAbsoluteTimeGetCurrent()
    if now - bundleIDCacheClearedAt > 10 { bundleIDCache.removeAll(); bundleIDCacheClearedAt = now }  // PIDの再利用に備えて、10秒ごとに忘れる
    if let v = bundleIDCache[pid] { return v }
    let v = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    bundleIDCache[pid] = .some(v)
    return v
}

/// ウィンドウ1枚ぶんの、必要な情報だけ(辞書のままだと、走査のたびに変換が入って重いので、取得時に1回だけ変換する)
struct Win { var pid: Int32; var num: Int; var x: CGFloat; var width: CGFloat; var height: CGFloat; var alpha: Double }

func parseWindows(_ infos: [[String: Any]]) -> [Win] {
    var out: [Win] = []
    out.reserveCapacity(infos.count)
    for w in infos {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? Int32,
              let bd = w[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bd["X"], let width = bd["Width"], let h = bd["Height"] else { continue }
        out.append(Win(pid: pid, num: (w[kCGWindowNumber as String] as? Int) ?? 0, x: x, width: width, height: h,
                       alpha: (w[kCGWindowAlpha as String] as? Double) ?? 1))
    }
    return out
}

/// いま表示されているウィンドウ(前面から順)。1回のパン更新につき1回だけ取得して、使い回す
var windows: [Win] = []
var lastWindowX: [Int: CGFloat] = [:]
/// 全ディスプレイを並べた範囲(取得のたびに更新)
var screenMinX: CGFloat = 0, screenMaxX: CGFloat = 1
/// デスクトップ(Space)の切り替えなどでウィンドウが一斉に動いている間は、この時刻までパンを動かさない
var transitionUntil: CFAbsoluteTime = 0

/// ウィンドウ一覧を取得し直し、デスクトップの切り替え(多数のウィンドウが一斉に動く・出入りする)を検出する
func refreshWindows() {
    let screens = NSScreen.screens
    if let mn = screens.map({ $0.frame.minX }).min(), let mx = screens.map({ $0.frame.maxX }).max() { screenMinX = mn; screenMaxX = mx }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    windows = parseWindows((CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? [])
    var xs: [Int: CGFloat] = [:]
    for w in windows { xs[w.num] = w.x }
    if !lastWindowX.isEmpty {
        var moved = 0, appeared = 0
        for (k, x) in xs { if let o = lastWindowX[k] { if abs(o - x) > 20 { moved += 1 } } else { appeared += 1 } }
        let vanished = lastWindowX.keys.filter { xs[$0] == nil }.count
        if moved >= 3 || appeared + vanished >= 3 {
            if CFAbsoluteTimeGetCurrent() >= transitionUntil { log("transition start moved=\(moved) appeared=\(appeared) vanished=\(vanished)") }
            transitionUntil = CFAbsoluteTimeGetCurrent() + 0.5
        }
    }
    lastWindowX = xs
}

/// 画面全体(全ディスプレイを並べた幅)に対する、X座標の中心位置から、パン(-1...1)を求める
func panValue(x: CGFloat, width: CGFloat) -> Float? {
    guard screenMaxX > screenMinX else { return nil }
    let cx = x + width / 2
    return Float(max(-1, min(1, ((cx - screenMinX) / (screenMaxX - screenMinX) * 2 - 1) * panGain)))
}

/// 指定PIDの最前面の通常ウィンドウについて、画面全体に対する中心位置(-1...1)を返す
func panPosition(forPID pid: pid_t) -> Float? { panPosition(matching: { $0 == pid }) }

/// 条件に合うプロセスの、最前面の通常ウィンドウの位置(-1...1)。いま表示されているウィンドウだけが対象
func panPosition(matching match: (pid_t) -> Bool) -> Float? {
    // 前面から順に並んでいるので、そのアプリの最初の通常ウィンドウを使う
    for w in windows where w.width > 50 && match(w.pid) { return panValue(x: w.x, width: w.width) }
    return nil
}

var lastPanSource = ""
var lastLoggedPan: [String: Float] = [:]
func logPan(_ key: String, _ v: Float, _ src: String) {
    guard debug else { return }
    if let o = lastLoggedPan[key], abs(o - v) < 0.05 { return }
    lastLoggedPan[key] = v
    log(String(format: "pan[%@]=%.2f src=%@", key, v, src))
}

/// すべてのウィンドウ(他のデスクトップにあるものも含む)。重いので、3秒ごとにだけ取得し直す
var allWindows: [Win] = []
var allWindowsFetchedAt: CFAbsoluteTime = 0

/// 条件に合うプロセスのウィンドウの位置(-1...1)。いま表示されているウィンドウを優先し、
/// なければ、他のデスクトップにあるウィンドウのうち、いちばん大きいものを使う
/// (切り替えたデスクトップに、音を鳴らしているアプリのウィンドウがなくても、そのアプリの位置から鳴らすため)
func panPositionAnySpace(matching match: (pid_t) -> Bool) -> Float? {
    if let p = panPosition(matching: match) { lastPanSource = "onscreen"; return p }
    lastPanSource = "anyspace"
    let now = CFAbsoluteTimeGetCurrent()
    if now - allWindowsFetchedAt > 3.0 {
        allWindows = parseWindows((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? [])
        allWindowsFetchedAt = now
    }
    var best: Win?
    for w in allWindows where w.width > 300 && w.height > 200 && w.alpha > 0 {
        guard w.x + w.width / 2 >= screenMinX, w.x + w.width / 2 <= screenMaxX else { continue }  // 画面の外にある補助ウィンドウは除く
        if best == nil || w.width * w.height > best!.width * best!.height, match(w.pid) { best = w }
    }
    guard let b = best else { return nil }
    return panValue(x: b.x, width: b.width)
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

func setPan(_ st: PanState, _ pan: Float) {
    st.left = min(1, 1 - pan)
    st.right = min(1, 1 + pan)
}

var tickCount = 0
func updatePan() {
    if noWindows { return }
    // どのタップにも、しばらく音が来ていないときは、3回に1回だけ更新する(待機中のCPU使用を減らすため)
    tickCount += 1
    let now = CFAbsoluteTimeGetCurrent()
    let lastSound = max(sysState.lastSound, appEngines.values.map { $0.state.lastSound }.max() ?? 0)
    if now - lastSound > 1.5 && tickCount % 3 != 0 { return }
    refreshWindows()
    // デスクトップの切り替え中は、ウィンドウがスライドして動くので、パンを動かさない(切り替えが終わるまで、直前の位置のまま)
    if CFAbsoluteTimeGetCurrent() < transitionUntil { return }
    // --- システム音 ---
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
            if let p = panPositionAnySpace(matching: { $0 == app.processIdentifier }) { pan = p; break }
        }
    }
    if pan == nil, let app = NSWorkspace.shared.frontmostApplication {
        pan = panPosition(forPID: app.processIdentifier)
    }
    if let pan { setPan(sysState, pan) }

    // --- アプリの音。タップごとに、そのアプリ自身のウィンドウ位置を基準にする ---
    for (key, e) in appEngines {
        var apan: Float?
        if key == "browser" {
            apan = panPositionAnySpace(matching: { pid in
                guard let id = cachedBundleID(pid) else { return false }
                return isBrowserBundleID(id)
            })
        } else {
            let appID = String(key.dropFirst(4))
            apan = panPositionAnySpace(matching: { pid in
                guard let id = cachedBundleID(pid) else { return false }
                return id == appID || id.hasPrefix(appID + ".")
            })
        }
        // ウィンドウが見えていなければ、最前面アプリの位置
        if apan == nil, let app = NSWorkspace.shared.frontmostApplication {
            lastPanSource = "frontmost"
            apan = panPosition(forPID: app.processIdentifier)
        }
        if let apan { setPan(e.state, apan); logPan(key, apan, lastPanSource) }
    }
}

// MARK: - tap engine
final class TapEngine {
    let name: String
    let state: PanState
    var starting = false
    let queue: DispatchQueue
    init(name: String, state: PanState) { self.name = name; self.state = state; self.queue = DispatchQueue(label: "engine-" + name) }
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    var activeObjects: [AudioObjectID] = []
    var activeOutputUID: String?
    var running: Bool { procID != nil }

    func start(objects: [AudioObjectID], outputUID: String) -> Bool {
        let desc = CATapDescription(stereoMixdownOfProcesses: objects)
        desc.uuid = UUID()
        desc.name = "SystemSoundPan-" + name
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

        let state = self.state
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            let outList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: outData))
            // 文字列の組み立ては、音声処理のたびにメモリ確保が起きるので、デバッグ時だけ行う
            if debug { state.calls += 1; state.info = "in=\(inList.count) out=\(outList.count) inCh=\(inList.count > 0 ? inList[0].mNumberChannels : 0) inBytes=\(inList.count > 0 ? inList[0].mDataByteSize : 0)" }
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
            var framePeak: Float = 0
            for i in 0..<frames { framePeak = max(framePeak, abs(l[i * inStride])) }
            state.inPeak = max(state.inPeak, framePeak)
            if framePeak > 0.02 { state.lastSound = CFAbsoluteTimeGetCurrent() }
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
    let sysEngine = TapEngine(name: "system", state: sysState)
    let watcher = NotificationWatcher()
    var item: NSStatusItem!
    var enabled = true
    var toggle: NSMenuItem!
    var browserItem: NSMenuItem!
    var gainItem: NSMenuItem!
    var extraMenu = NSMenu()

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
        let extraItem = NSMenuItem(title: "パン対象のアプリ(アプリ自身が鳴らす音)", action: nil, keyEquivalent: "")
        extraItem.submenu = extraMenu
        menu.addItem(extraItem)
        rebuildExtraMenu()
        gainItem = NSMenuItem(title: "", action: #selector(editGain), keyEquivalent: "")
        gainItem.target = self
        updateGainTitle()
        menu.addItem(gainItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in updatePan() }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.reconcile() }
        if debug {
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in log("calls=\(sysState.calls) inPeak=\(sysState.inPeak) \(sysState.info)") }
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            if sysState.peak > 0.001 {
                log(String(format: "sound peak=%.3f L=%.2f R=%.2f", sysState.peak, sysState.left, sysState.right))
                sysState.peak = 0
            }
            for (k, e) in appEngines where e.state.peak > 0.001 {
                log(String(format: "app[\(k)] sound peak=%.3f L=%.2f R=%.2f", e.state.peak, e.state.left, e.state.right))
                e.state.peak = 0
            }
        }
        }
        reconcile()
        if !noWatcher { watcher.start() }
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

    func rebuildExtraMenu() {
        extraMenu.removeAllItems()
        if extraApps.isEmpty {
            let none = NSMenuItem(title: "(追加したアプリはありません)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            extraMenu.addItem(none)
        }
        for (i, a) in extraApps.enumerated() {
            let m = NSMenuItem(title: a.name, action: #selector(toggleExtra(_:)), keyEquivalent: "")
            m.target = self; m.tag = i; m.state = a.on ? .on : .off
            extraMenu.addItem(m)
        }
        extraMenu.addItem(.separator())
        let add = NSMenuItem(title: "アプリを追加…", action: #selector(addExtra), keyEquivalent: "")
        add.target = self
        extraMenu.addItem(add)
        if !extraApps.isEmpty {
            let rm = NSMenuItem(title: "アプリを削除", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (i, a) in extraApps.enumerated() {
                let m = NSMenuItem(title: a.name, action: #selector(removeExtra(_:)), keyEquivalent: "")
                m.target = self; m.tag = i
                sub.addItem(m)
            }
            rm.submenu = sub
            extraMenu.addItem(rm)
        }
    }

    @objc func toggleExtra(_ sender: NSMenuItem) {
        guard extraApps.indices.contains(sender.tag) else { return }
        extraApps[sender.tag].on.toggle()
        saveExtraApps(); rebuildExtraMenu(); reconcile()
    }

    @objc func removeExtra(_ sender: NSMenuItem) {
        guard extraApps.indices.contains(sender.tag) else { return }
        extraApps.remove(at: sender.tag)
        saveExtraApps(); rebuildExtraMenu(); reconcile()
    }

    @objc func addExtra() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "パンの対象にするアプリを選んでください"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier else {
            let e = NSAlert(); e.messageText = "このアプリのバンドルIDを読み取れませんでした"; e.runModal(); return
        }
        guard !extraApps.contains(where: { $0.id == id }) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        extraApps.append(ExtraApp(id: id, name: name, on: true))
        saveExtraApps(); rebuildExtraMenu(); reconcile()
        log("extra app added: \(id)")
    }

    @objc func toggleBrowser() {
        browserMode.toggle()
        UserDefaults.standard.set(browserMode, forKey: "browserMode")
        browserItem.state = browserMode ? .on : .off
        log("browserMode = \(browserMode)")
        reconcile()
    }

    func reconcile() {
        if noTap { return }
        guard enabled else {
            for e in [sysEngine] + Array(appEngines.values) where e.running { e.queue.async { e.stop() } }
            return
        }
        let (sys, groups) = processObjects()
        browserObjectIDs = groups["browser"] ?? []
        let uid = defaultOutputUID()
        log("reconcile sys=\(sys) groups=\(groups) uid=\(uid ?? "nil")")
        sync(sysEngine, objs: sys, uid: uid)
        // なくなったグループのタップは止めて捨てる
        for (k, e) in appEngines where groups[k] == nil {
            e.queue.async { e.stop() }
            appEngines[k] = nil
        }
        for (k, objs) in groups {
            let e = appEngines[k] ?? TapEngine(name: k, state: PanState())
            appEngines[k] = e
            sync(e, objs: objs, uid: uid)
        }
    }

    /// タップの対象が変わったときだけ、そのタップを作り直す
    func sync(_ e: TapEngine, objs: [AudioObjectID], uid: String?) {
        guard let uid, !objs.isEmpty else { if e.running { log("\(e.name): target gone"); e.queue.async { e.stop() } }; return }
        if e.starting { return }
        if e.running && e.activeObjects == objs && e.activeOutputUID == uid { return }
        e.starting = true
        e.queue.async {
            e.stop()
            let ok = e.start(objects: objs, outputUID: uid)
            log("\(e.name): start result \(ok)")
            DispatchQueue.main.async { e.starting = false }
        }
    }

    func applicationWillTerminate(_ n: Notification) { watcher.stop(); sysEngine.stop(); for e in appEngines.values { e.stop() } }
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

