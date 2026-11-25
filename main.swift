import AppKit
import AudioToolbox
import CoreAudio
import CoreImage
import CoreImage.CIFilterBuiltins
import Network
import Security
import SystemConfiguration

let port: UInt16 = 8787
let frameSamples = 1024

// Access key: the stream is the Mac's sound, so only devices given the link may read it.
let key: String = {
    if let k = UserDefaults.standard.string(forKey: "key") { return k }
    var b = [UInt8](repeating: 0, count: 12)
    guard SecRandomCopyBytes(kSecRandomDefault, b.count, &b) == errSecSuccess else { fatalError("no random bytes") }
    let k = b.map { String(format: "%02x", $0) }.joined()
    UserDefaults.standard.set(k, forKey: "key")
    return k
}()

func check(_ s: OSStatus, _ what: String) -> Bool {
    if s != noErr { NSLog("Butterchurn: %@ failed (%d)", what, s) }
    return s == noErr
}

// MARK: - System audio

final class SystemAudio {
    private var left = [Float](repeating: 0, count: frameSamples)
    private var right = [Float](repeating: 0, count: frameSamples)
    private var pos = 0
    private var lastInput = 0.0
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "audio", qos: .userInteractive)

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?

    private var outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    init() {
        start()
        // Headset connected or removed: rebuild the tap on the new output.
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, .main) { [weak self] _, _ in
            self?.stop()
            self?.start()
        }
    }

    private func start() {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        guard check(AudioHardwareCreateProcessTap(desc, &tap), "create tap") else { return }
        // Tap only, no hardware device inside: a Bluetooth headset would otherwise switch to call mode.
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Butterchurn",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "create aggregate device") else { stop(); return }
        guard check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, { [weak self] _, input, _, _, _ in
            self?.receive(input)
        }), "create IO proc") else { stop(); return }
        if !check(AudioDeviceStart(aggregate, proc), "start audio") { stop() }
    }

    private func stop() {
        if aggregate != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let a = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = Int(first.mNumberChannels)
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        // Interleaved stereo in one buffer, or one buffer per channel.
        let b = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        lock.lock()
        for i in 0..<count {
            left[pos] = a[i * channels]
            right[pos] = b.map { $0[i * channels] } ?? a[i * channels + (channels > 1 ? 1 : 0)]
            pos = (pos + 1) % frameSamples
        }
        lastInput = CACurrentMediaTime()
        lock.unlock()
    }

    /// Send time in ms (Float64), then 1024 bytes each of mono, left, right, centred on 128.
    func frame() -> Data {
        func byte(_ v: Float) -> UInt8 { UInt8(max(0, min(255, 128 + v * 128))) }
        let now = CACurrentMediaTime()
        var ms = now * 1000
        var out = Data(bytes: &ms, count: 8)
        var bytes = [UInt8](repeating: 128, count: frameSamples * 3)
        lock.lock()
        if now - lastInput < 0.2 {
            for i in 0..<frameSamples {
                let l = left[(pos + i) % frameSamples], r = right[(pos + i) % frameSamples]
                bytes[i] = byte((l + r) / 2)
                bytes[frameSamples + i] = byte(l)
                bytes[2 * frameSamples + i] = byte(r)
            }
        }
        lock.unlock()
        out.append(contentsOf: bytes)
        return out
    }
}

// MARK: - Server

func wifiAddress() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return nil }
    defer { freeifaddrs(list) }
    var p = list
    while let i = p {
        p = i.pointee.ifa_next
        guard let addr = i.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        guard String(cString: i.pointee.ifa_name) == "en0" else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            return String(cString: host)
        }
    }
    return nil
}

func qrPNG(_ text: String) -> Data? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(text.utf8)
    guard let img = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
    return NSBitmapImageRep(ciImage: img).representation(using: .png, properties: [:])
}

final class Server {
    private final class Client {
        let conn: NWConnection
        var inFlight = 0
        init(_ c: NWConnection) { conn = c }
    }

    private let audio: SystemAudio
    private let queue = DispatchQueue(label: "server", qos: .userInteractive)
    private let listener: NWListener
    private var listeners: [ObjectIdentifier: Client] = [:]
    private var timer: DispatchSourceTimer?

    init(audio: SystemAudio) throws {
        self.audio = audio
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [unowned self] c in
            c.start(queue: queue)
            read(c, Data())
        }
        listener.stateUpdateHandler = { state in
            guard case .failed(let error) = state else { return }
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "Butterchurn could not open port \(port)"
                a.informativeText = error.localizedDescription
                a.runModal()
                NSApp.terminate(nil)
            }
        }
        listener.start(queue: queue)

        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .microseconds(16_667), leeway: .milliseconds(1))
        t.setEventHandler { [unowned self] in broadcast() }
        t.resume()
        timer = t
    }

    private func broadcast() {
        if listeners.isEmpty { return }
        let data = audio.frame()
        // A slow client skips frames instead of building up lag.
        for c in listeners.values where c.inFlight < 4 {
            c.inFlight += 1
            c.conn.send(content: data, completion: .contentProcessed { _ in c.inFlight -= 1 })
        }
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [unowned self] data, _, done, error in
            let all = buffer + (data ?? Data())
            if let end = all.range(of: Data("\r\n\r\n".utf8)) {
                respond(c, String(decoding: all[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil || all.count > 16384 {
                c.cancel()
            } else {
                read(c, all)
            }
        }
    }

    private func respond(_ c: NWConnection, _ request: String) {
        let parts = request.split(separator: "\r\n").first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET", let url = URLComponents(string: String(parts[1])) else { return send(c, 400) }
        let allowed = url.queryItems?.first { $0.name == "k" }?.value == key

        switch url.path {
        case "/audio":
            guard allowed else { return send(c, 403) }
            let client = Client(c)
            let id = ObjectIdentifier(client)
            c.stateUpdateHandler = { [unowned self] s in
                switch s {
                case .failed, .cancelled: listeners[id] = nil
                default: break
                }
            }
            // Nothing more is expected from the client; a read ends when it goes away.
            c.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in c.cancel() }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            listeners[id] = client
        case "/info":
            guard allowed else { return send(c, 403) }
            let name = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
            let urls = [wifiAddress(), name].compactMap { $0 }.map { "http://\($0):\(port)/?k=\(key)" }
            send(c, 200, try? JSONEncoder().encode(urls), "application/json")
        case "/qr.png":
            guard allowed, let ip = wifiAddress() else { return send(c, 403) }
            send(c, 200, qrPNG("http://\(ip):\(port)/?k=\(key)"), "image/png")
        default:
            let files = ["/": "index.html", "/butterchurn.min.js": "", "/butterchurnPresets.min.js": "", "/butterchurnPresetsExtra.min.js": ""]
            guard let f = files[url.path] else { return send(c, 404) }
            let name = f.isEmpty ? String(url.path.dropFirst()) : f
            let data = try? Data(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("web/\(name)"))
            send(c, 200, data, name.hasSuffix("js") ? "text/javascript" : "text/html; charset=utf-8")
        }
    }

    private func send(_ c: NWConnection, _ status: Int, _ body: Data? = nil, _ type: String = "text/plain") {
        let body = body ?? Data("\(status)".utf8)
        let head = "HTTP/1.1 \(status) -\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var server: Server?
    var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu(), item = NSMenuItem()
        item.submenu = NSMenu()
        item.submenu!.addItem(withTitle: "Open in browser", action: #selector(openPage), keyEquivalent: "o")
        item.submenu!.addItem(withTitle: "Quit Butterchurn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(item)
        NSApp.mainMenu = menu

        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Streaming sound levels")
        do {
            server = try Server(audio: SystemAudio())
            openPage()
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ a: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openPage()
        return false
    }

    @objc func openPage() {
        NSWorkspace.shared.open(URL(string: "http://localhost:\(port)/?k=\(key)")!)
    }
}

let delegate = AppDelegate()
NSApplication.shared.setActivationPolicy(.regular)
NSApp.delegate = delegate
NSApp.run()
