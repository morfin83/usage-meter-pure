import AppKit
import Foundation
import IOKit
import SystemConfiguration
import Darwin
import CoreImage


let uiLanguage = Bundle.preferredLocalizations(from: ["en", "cs"], forPreferences: Locale.preferredLanguages).first ?? "en"
let uiStrings: [String: String] = {
    guard let url = Bundle.main.url(forResource: uiLanguage, withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let strings = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
    return strings
}()
func L(_ key: String) -> String { uiStrings[key] ?? key }
func LF(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), locale: Locale.current, arguments: args) }

// All readings are local to the Mac running this app, never the remote model host.
struct InterfaceSample {
    let name: String
    let received: UInt64
    let sent: UInt64
    let speed: UInt64
}

final class SystemSampler {
    private var previousCPU: [UInt32]?
    private var previousCores: [[UInt32]]?
    private var previousNetwork: InterfaceSample?
    private var previousTime = ProcessInfo.processInfo.systemUptime

    func cpu() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { previousCPU = ticks }
        guard let old = previousCPU else { return nil }
        let delta = zip(ticks, old).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        return total > 0 ? (total - delta[2]) / total * 100 : 0
    }

    func cpuCores() -> [Double?] {
        var cores: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count) == KERN_SUCCESS,
              let info = info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        guard Int(count) >= Int(cores) * 4 else { return [] }
        let ticks: [[UInt32]] = (0..<Int(cores)).map { core in
            (0..<4).map { UInt32(bitPattern: info[core * 4 + $0]) }
        }
        defer { previousCores = ticks }
        guard let old = previousCores, old.count == ticks.count else {
            return Array(repeating: nil, count: ticks.count)
        }
        return zip(ticks, old).map { current, previous in
            let delta = zip(current, previous).map { Double($0 &- $1) }
            let total = delta.reduce(0, +)
            return total > 0 ? (total - delta[2]) / total * 100 : 0
        }
    }

    func gpuCoreCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        // Core list is only unambiguous for a single GPU device.
        var counts: [Int] = []
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            if let property = IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let number = property as? NSNumber, number.intValue > 0, number.intValue <= 256 {
                counts.append(number.intValue)
            }
        }
        return counts.count == 1 ? counts[0] : nil
    }

    func ram() -> Double? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Active + wired + physical compressor pages. This is not memory pressure.
        let pages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return Double(pages) * Double(vm_kernel_page_size) / Double(ProcessInfo.processInfo.physicalMemory) * 100
    }

    func gpu() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var values: [Double] = []
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            if let value = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let stats = value as? [String: Any],
               let number = stats["Device Utilization %"] as? NSNumber {
                let percent = number.doubleValue
                if percent.isFinite && percent >= 0 && percent <= 100 { values.append(percent) }
            }
        }
        // Multiple devices: show the busiest GPU, never sum percentages.
        return values.max()
    }

    func interfaceSample() -> InterfaceSample? {
        guard let store = SCDynamicStoreCreate(nil, "UsageMeter" as CFString, nil, nil) else { return nil }
        let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let ipv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
        guard let name = (ipv4?["PrimaryInterface"] ?? ipv6?["PrimaryInterface"]) as? String else { return nil }
        let wanted = if_nametoindex(name)
        guard wanted > 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: MemoryLayout<if_msghdr2>.alignment)
        defer { buffer.deallocate() }
        guard sysctl(&mib, u_int(mib.count), buffer, &length, nil, 0) == 0 else { return nil }
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let ptr = buffer.advanced(by: offset)
            let header = ptr.loadUnaligned(as: if_msghdr.self)
            let messageLength = Int(header.ifm_msglen)
            guard messageLength > 0, offset + messageLength <= length else { break }
            if header.ifm_type == RTM_IFINFO2 && messageLength >= MemoryLayout<if_msghdr2>.size {
                let info = ptr.loadUnaligned(as: if_msghdr2.self)
                if UInt32(info.ifm_index) == wanted {
                    return InterfaceSample(name: name, received: info.ifm_data.ifi_ibytes,
                                           sent: info.ifm_data.ifi_obytes, speed: info.ifm_data.ifi_baudrate)
                }
            }
            offset += messageLength
        }
        return nil
    }

    func network() -> (Double?, String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let current = interfaceSample() else {
            previousNetwork = nil
            previousTime = now
            return (nil, L("Rychlost aktivního síťového rozhraní není dostupná."))
        }
        defer { previousNetwork = current; previousTime = now }
        guard current.speed > 0 else {
            return (nil, LF("%@: systém neudává kapacitu linky. Procento nelze určit.", current.name))
        }
        guard let old = previousNetwork, old.name == current.name,
              now > previousTime, current.received >= old.received, current.sent >= old.sent else {
            return (nil, LF("První vzorek: %@, %@ Mb/s.", current.name, String(current.speed / 1_000_000)))
        }
        // Full duplex: take the busier direction, rather than adding RX and TX.
        let bitsPerSecond = Double(max(current.received - old.received, current.sent - old.sent)) * 8 / (now - previousTime)
        return (min(100, bitsPerSecond / Double(current.speed) * 100),
                LF("%@: %@ Mb/s. Vytížení = vyšší z příjmu a odesílání / rychlost linky; nejde o rychlost internetového tarifu.", current.name, String(current.speed / 1_000_000)))
    }

    func sample() -> [String: Any] {
        let net = network()
        return ["cpu": cpu() as Any? ?? NSNull(), "ram": ram() as Any? ?? NSNull(),
                "gpu": gpu() as Any? ?? NSNull(), "network": net.0 as Any? ?? NSNull(),
                "networkExplanation": net.1,
                "cpuCores": cpuCores().map { $0 as Any? ?? NSNull() },
                "gpuCoreCount": gpuCoreCount() as Any? ?? NSNull(),
                "gpuPerCoreAvailable": false]
    }
}

enum Palette {
    static let quota = NSColor(srgbRed: 0.65, green: 0.87, blue: 0.74, alpha: 1)
    static let weekly = NSColor(srgbRed: 0.97, green: 0.86, blue: 0.57, alpha: 1)
    static let cpu = NSColor(srgbRed: 0.63, green: 0.79, blue: 0.97, alpha: 1)
    static let ram = NSColor(srgbRed: 0.96, green: 0.70, blue: 0.75, alpha: 1)
    static let gpu = NSColor(srgbRed: 0.79, green: 0.70, blue: 0.95, alpha: 1)
    static let network = NSColor(srgbRed: 0.62, green: 0.87, blue: 0.88, alpha: 1)
    static let claude = NSColor(srgbRed: 0.87, green: 0.64, blue: 0.50, alpha: 1)
}

final class PastelBar: NSView {
    var doubleValue: Double = 0 { didSet { needsDisplay = true; setAccessibilityValue(doubleValue) } }
    var tint = Palette.cpu
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let width = bounds.width * CGFloat(max(0, min(100, doubleValue))) / 100
        if width > 0 {
            tint.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: 3, yRadius: 3).fill()
        }
    }
}

final class MeterRow: NSView {
    let label = NSTextField(labelWithString: "")
    let value = NSTextField(labelWithString: "—")
    let progress = PastelBar(frame: .zero)
    let coreSwitch = NSSwitch()
    var remaining = false

    init(_ title: String, remaining: Bool = false, tint: NSColor = Palette.cpu, compact: Bool = false) {
        super.init(frame: .zero)
        self.remaining = remaining
        label.stringValue = title
        label.font = .systemFont(ofSize: compact ? 9 : 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: compact ? 9 : 12, weight: .semibold)
        value.alignment = .right
        coreSwitch.controlSize = .mini
        coreSwitch.isHidden = true
        let line = NSStackView(views: [label, NSView(), value, coreSwitch])
        line.orientation = .horizontal
        progress.tint = tint
        progress.setAccessibilityLabel(title)
        let stack = NSStackView(views: [line, progress])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalTo: stack.widthAnchor), progress.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ percent: Double?, tooltip: String? = nil) {
        guard let percent = percent, percent.isFinite else {
            value.stringValue = "—"
            progress.doubleValue = 0
            progress.alphaValue = 0.45
            progress.setAccessibilityValue(L("Nedostupné"))
            value.textColor = .secondaryLabelColor
            toolTip = tooltip ?? L("Údaj není dostupný.")
            return
        }
        let p = max(0, min(100, percent))
        value.stringValue = String(format: "%.0f %%", p)
        progress.doubleValue = p
        progress.alphaValue = 1
        let warning = remaining ? p < 15 : p > 85
        value.textColor = warning ? .systemOrange : .labelColor
        toolTip = tooltip
    }
}

final class DragHeader: NSStackView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var aiBody: NSStackView!
    let aiSwitch = NSSwitch()
    var footerTimer: Timer?
    var footerDetails: NSStackView!
    var positioned = false
    var resizing = false
    var userClosed = false
    var expandedWindow = false
    let sampler = SystemSampler()
    var panel: OverlayPanel!
    var statusItem: NSStatusItem!
    var root: NSStackView!
    var body: NSStackView!
    var details: NSStackView!
    var cpuDetail: NSStackView!
    var gpuDetail: NSStackView!
    var cpuRows: [MeterRow] = []
    var gpuRows: [MeterRow] = []
    var scroll: NSScrollView!
    var canvas: NSView!
    let showSwitch = NSSwitch()
    let detailSwitch = NSSwitch()
    let quota = GaugeRow(L("Zbývá · krátkodobý limit"), key: "codex.5h", tint: Palette.quota, series: \.five)
    let weekly = GaugeRow(L("Zbývá · dlouhodobý limit"), key: "codex.week", tint: Palette.weekly, series: \.week)
    let cpu = MeterRow("CPU", tint: Palette.cpu)
    let ram = MeterRow("RAM", tint: Palette.ram)
    let gpu = MeterRow("GPU", tint: Palette.gpu)
    let network = MeterRow(L("Síť"), tint: Palette.network)
    let updated = NSTextField(labelWithString: L("Limity: načítání…"))
    let creditLabel = NSTextField(labelWithString: L("Kredity: API neposkytuje zůstatek"))
    let codexTokensLabel = NSTextField(labelWithString: L("Tokeny z Codex logů: načítání…"))
    let codexTitle = NSTextField(labelWithString: "Codex")
    let codexActivityButton = NSButton(title: "", target: nil, action: nil)
    lazy var codexActivity = CodexActivityWindow()
    let claudeTitle = NSTextField(labelWithString: "Claude")
    let claudeFive = GaugeRow(L("Claude · zbývá 5 h"), key: "claude.5h", tint: Palette.claude, series: \.five)
    let claudeWeek = GaugeRow(L("Claude · zbývá týden"), key: "claude.week", tint: Palette.claude, series: \.week)
    let claudeTokens = NSTextField(labelWithString: "")
    let claudeUpdated = NSTextField(labelWithString: L("Claude: načítání…"))
    let claudeSetupLabel = NSTextField(labelWithString: "")
    let claudeLive = NSTextField(labelWithString: "")
    var telemetryTimer: Timer?
    var usageTimer: Timer?
    var isFetching = false
    var pinnedEverywhere = true
    var lastUsage: Date?
    var lastFetchFailed = false
    var usageProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let binary = Bundle.main.executablePath {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let state = ClaudeSetup.install(binary: binary)
                DispatchQueue.main.async { self?.claudeSetupLabel.stringValue = state.label }
            }
        }
        UserDefaults.standard.register(defaults: ["showPanelDetails": true, "showAI": true,
            "showMac": true, "showCPUCores": true, "showGPUCores": true, "showEverywhere": true])
        pinnedEverywhere = UserDefaults.standard.bool(forKey: "showEverywhere")
        createStatusItem()
        createPanel()
        sample()
        fetchUsage()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sample()
        }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetchUsage()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(focusChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        focusChanged()
    }

    func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Usage Meter")
        statusItem.button?.toolTip = L("Usage Meter Pure · limity a výkon Macu")
        let menu = NSMenu()
        menu.addItem(withTitle: L("Otevřít Usage Meter Pure"), action: #selector(toggleFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: L("Obnovit limity"), action: #selector(refresh), keyEquivalent: "")
        menu.addItem(withTitle: L("Zobrazovat i nad jinými aplikacemi"), action: #selector(toggleEverywhere(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Ukončit Usage Meter"), action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        menu.items[2].state = pinnedEverywhere ? .on : .off
        statusItem.menu = menu
    }

    func createPanel() {
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 292, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.delegate = self
        panel.title = "Usage Meter Pure"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 292, height: 100)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        panel.contentView = effect
        panel.appearance = NSAppearance(named: .darkAqua)
        let title = NSTextField(labelWithString: "Usage Meter Pure")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "BY MORFIN83 · CODEX + MAC")
        subtitle.font = .systemFont(ofSize: 8, weight: .semibold)
        subtitle.textColor = .secondaryLabelColor
        let titles = vertical([title, subtitle], spacing: 2)
        showSwitch.state = UserDefaults.standard.bool(forKey: "showPanelDetails") ? .on : .off
        showSwitch.controlSize = .mini
        showSwitch.target = self
        showSwitch.action = #selector(toggleShow)
        showSwitch.setAccessibilityLabel(L("Zobrazit nebo skrýt údaje"))
        showSwitch.toolTip = L("Zobrazit / skrýt údaje; přepínač zůstane dostupný.")
        let showLabel = NSTextField(labelWithString: L("Zobrazit"))
        showLabel.font = .systemFont(ofSize: 10)
        let header = DragHeader(views: [titles, NSView(), showLabel, showSwitch])
        header.toolTip = L("Přetažením přesuňte panel")
        header.orientation = .horizontal
        header.spacing = 6
        detailSwitch.state = UserDefaults.standard.bool(forKey: "showMac") ? .on : .off
        detailSwitch.controlSize = .mini
        detailSwitch.target = self
        detailSwitch.action = #selector(toggleDetails)
        detailSwitch.setAccessibilityLabel(L("Parametry Macu"))
        let detailLabel = NSTextField(labelWithString: L("Parametry Macu"))
        detailLabel.font = .systemFont(ofSize: 11)
        let detailToggle = NSStackView(views: [detailLabel, NSView(), detailSwitch])
        detailToggle.orientation = .horizontal
        cpuDetail = vertical([], spacing: 8)
        gpuDetail = vertical([], spacing: 8)
        for row in [cpu, gpu] {
            row.coreSwitch.isHidden = false
            row.coreSwitch.state = UserDefaults.standard.bool(forKey: row === cpu ? "showCPUCores" : "showGPUCores") ? .on : .off
            row.coreSwitch.target = self
            row.coreSwitch.action = #selector(toggleCores)
            row.coreSwitch.setAccessibilityLabel(L("Jednotlivá jádra ") + row.label.stringValue)
            row.coreSwitch.toolTip = L("Zobrazit / skrýt jednotlivá jádra")
        }
        buildCoreGrid(cpuDetail, count: ProcessInfo.processInfo.activeProcessorCount, tint: Palette.cpu, into: &cpuRows)
        buildCoreGrid(gpuDetail, count: sampler.gpuCoreCount() ?? 0, tint: Palette.gpu, into: &gpuRows)
        let gpuNotice = NSTextField(wrappingLabelWithString: L("macOS neposkytuje vytížení jednotlivých GPU jader. — = nedostupné."))
        gpuNotice.font = .systemFont(ofSize: 9)
        gpuNotice.textColor = .secondaryLabelColor
        gpuDetail.addArrangedSubview(gpuNotice)
        gpuNotice.widthAnchor.constraint(equalTo: gpuDetail.widthAnchor).isActive = true
        details = vertical([separator(), cpu, cpuDetail, ram, gpu, gpuDetail, network], spacing: 12)
        details.isHidden = false
        creditLabel.font = .systemFont(ofSize: 9)
        creditLabel.textColor = .tertiaryLabelColor
        for title in [codexTitle, claudeTitle] {
            title.font = .systemFont(ofSize: 10, weight: .semibold)
            title.textColor = .secondaryLabelColor
        }
        claudeLive.font = .systemFont(ofSize: 9, weight: .medium)
        for note in [claudeTokens, claudeUpdated, claudeSetupLabel, codexTokensLabel] {
            note.font = .systemFont(ofSize: 9)
            note.textColor = .tertiaryLabelColor
        }
        updated.font = .systemFont(ofSize: 9)
        updated.textColor = .secondaryLabelColor
        updated.lineBreakMode = .byTruncatingTail
        let copyright = NSTextField(labelWithString: L("© Vyrobilo Studio Pure Sound."))
        copyright.font = .systemFont(ofSize: 8)
        copyright.textColor = .secondaryLabelColor
        copyright.alignment = .center
        aiSwitch.state = UserDefaults.standard.bool(forKey: "showAI") ? .on : .off
        aiSwitch.controlSize = .mini
        aiSwitch.target = self
        aiSwitch.action = #selector(toggleAI)
        aiSwitch.setAccessibilityLabel(L("Zobrazit AI"))
        let aiHeader = NSStackView(views: [NSTextField(labelWithString: "AI"), NSView(), aiSwitch])
        aiHeader.orientation = .horizontal
        // Status notes may need two lines; wrap them inside the panel width.
        for note in [claudeUpdated, claudeSetupLabel] {
            note.maximumNumberOfLines = 0
            note.lineBreakMode = .byWordWrapping
            note.preferredMaxLayoutWidth = 260
        }
        codexActivityButton.title = L("Aktivita ▸")
        codexActivityButton.bezelStyle = .inline
        codexActivityButton.font = .systemFont(ofSize: 10)
        codexActivityButton.target = self
        codexActivityButton.action = #selector(toggleCodexActivity)
        let codexHeader = NSStackView(views: [codexTitle, NSView(), codexActivityButton])
        codexHeader.orientation = .horizontal
        aiBody = vertical([codexHeader, quota, weekly, creditLabel, codexTokensLabel, updated, claudeTitle, claudeFive, claudeWeek, claudeLive, claudeTokens, claudeUpdated, claudeSetupLabel], spacing: 12)
        for row in [quota, weekly, claudeFive, claudeWeek] { row.onChange = { [weak self] in self?.resize() } }
        let logo = NSImageView()
        if let url = Bundle.main.url(forResource: "purelogo", withExtension: "png"),
           let source = CIImage(contentsOf: url) {
            let white = source.applyingFilter("CIColorInvert").applyingFilter("CIMaskToAlpha")
            let rect = CGRect(x: source.extent.width * 0.11, y: source.extent.height * 0.36,
                              width: source.extent.width * 0.78, height: source.extent.height * 0.36)
            if let cg = CIContext().createCGImage(white, from: rect) {
                logo.image = NSImage(cgImage: cg, size: NSSize(width: 86, height: 20))
            }
        }
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.heightAnchor.constraint(equalToConstant: 24).isActive = true
        logo.setAccessibilityLabel("PURE")
        let web = NSButton(title: "www.studiopuresound.cz", target: self, action: #selector(openWebsite))
        web.isBordered = false
        web.font = .systemFont(ofSize: 10)
        body = vertical([separator(), aiHeader, aiBody, separator(), detailToggle, details], spacing: 12)
        footerDetails = vertical([web, copyright], spacing: 6)
        root = vertical([header, body, separator(), logo, footerDetails], spacing: 10)
        body.isHidden = showSwitch.state == .off
        aiBody.isHidden = aiSwitch.state == .off
        details.isHidden = detailSwitch.state == .off
        cpuDetail.isHidden = cpu.coreSwitch.state == .off
        gpuDetail.isHidden = gpu.coreSwitch.state == .off
        footerTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.footerDetails.isHidden = true
            self.resize()
        }
        root.translatesAutoresizingMaskIntoConstraints = false
        scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        canvas = NSView(frame: NSRect(x: 0, y: 0, width: 292, height: 700))
        canvas.addSubview(root)
        scroll.documentView = canvas
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 16),
            root.bottomAnchor.constraint(lessThanOrEqualTo: canvas.bottomAnchor, constant: -16)
        ])
        resize()
    }

    func buildCoreGrid(_ stack: NSStackView, count: Int, tint: NSColor, into rows: inout [MeterRow]) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        rows = (0..<count).map { MeterRow("\($0 + 1)", tint: tint, compact: true) }
        for start in stride(from: 0, to: rows.count, by: 4) {
            var cells: [NSView] = Array(rows[start..<min(start + 4, rows.count)])
            while cells.count < 4 { cells.append(NSView()) }
            let line = NSStackView(views: cells)
            line.orientation = .horizontal
            line.distribution = .fillEqually
            line.spacing = 10
            stack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for (index, row) in rows.enumerated() {
            row.progress.setAccessibilityLabel(LF("Jádro %@", String(index + 1)))
            row.update(nil)
        }
    }

    func saveSwitches() {
        let defaults = UserDefaults.standard
        defaults.set(showSwitch.state == .on, forKey: "showPanelDetails")
        defaults.set(aiSwitch.state == .on, forKey: "showAI")
        defaults.set(detailSwitch.state == .on, forKey: "showMac")
        defaults.set(cpu.coreSwitch.state == .on, forKey: "showCPUCores")
        defaults.set(gpu.coreSwitch.state == .on, forKey: "showGPUCores")
        defaults.set(pinnedEverywhere, forKey: "showEverywhere")
    }
    @objc func toggleCores() {
        saveSwitches()
        cpuDetail.isHidden = cpu.coreSwitch.state == .off
        gpuDetail.isHidden = gpu.coreSwitch.state == .off
        resize()
    }

    func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }
    func resize() {
        canvas.layoutSubtreeIfNeeded()
        let height = max(66, root.fittingSize.height + 32)
        if expandedWindow {
            canvas.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(height, scroll.contentSize.height)))
            return
        }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = screen else { return }
        let visible = screen.visibleFrame
        canvas.setFrameSize(NSSize(width: 292, height: height))
        let titleHeight = panel.frame.height - (panel.contentView?.frame.height ?? panel.frame.height)
        let newHeight = min(height + titleHeight, visible.height - 32)
        var origin = positioned ? NSPoint(x: panel.frame.minX, y: panel.frame.maxY - newHeight) : NSPoint(x: visible.maxX - 308, y: visible.minY + 16)
        if !positioned, let saved = UserDefaults.standard.string(forKey: "panelOrigin") { origin = NSPointFromString(saved) }
        let target = NSScreen.screens.first(where: { $0.visibleFrame.contains(origin) })?.visibleFrame ?? visible
        origin.x = max(target.minX, min(origin.x, target.maxX - 292))
        origin.y = max(target.minY, min(origin.y, target.maxY - newHeight))
        resizing = true
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: 292, height: newHeight)), display: true)
        resizing = false
        positioned = true
        canvas.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func windowDidMove(_ notification: Notification) {
        if positioned && !resizing { UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "panelOrigin") }
    }
    @objc func openWebsite() { NSWorkspace.shared.open(URL(string: "https://www.studiopuresound.cz")!) }
    @objc func toggleCodexActivity() { codexActivity.show() }

    @objc func toggleAI() { aiBody.isHidden = aiSwitch.state == .off; saveSwitches(); resize() }
    @objc func toggleShow() { body.isHidden = showSwitch.state == .off; saveSwitches(); resize() }
    @objc func toggleDetails() { details.isHidden = detailSwitch.state == .off; saveSwitches(); resize() }
    @objc func toggleFromMenu() {
        userClosed = false
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
    }
    @objc func toggleEverywhere(_ sender: NSMenuItem) {
        pinnedEverywhere.toggle()
        saveSwitches()
        sender.state = pinnedEverywhere ? .on : .off
        focusChanged()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        userClosed = true
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggleFromMenu()
        return true
    }
    func windowWillStartLiveResize(_ notification: Notification) { expandedWindow = true }
    func windowDidResize(_ notification: Notification) {
        if !resizing && canvas != nil && scroll != nil { resize() }
    }
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        expandedWindow = !window.isZoomed
        return true
    }
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }
    @objc func focusChanged() {
        guard !userClosed && !panel.isMiniaturized else { return }
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? ""
        let isTarget = ["Codex", "ChatGPT", "Usage Meter", "Usage Meter Pure"].contains(name)
        if pinnedEverywhere || isTarget {
            resize()
            panel.orderFrontRegardless()
        } else { panel.orderOut(nil) }
    }
    @objc func screenChanged() { resize() }
    @objc func refresh() { fetchUsage() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        saveSwitches()
        footerTimer?.invalidate()
        telemetryTimer?.invalidate()
        usageTimer?.invalidate()
        usageProcess?.terminate()
    }

    func sample() {
        let data = sampler.sample()
        let cores = data["cpuCores"] as? [Any] ?? []
        if !cores.isEmpty && cores.count != cpuRows.count {
            buildCoreGrid(cpuDetail, count: cores.count, tint: Palette.cpu, into: &cpuRows)
            resize()
        }
        for (index, row) in cpuRows.enumerated() {
            row.update(index < cores.count ? cores[index] as? Double : nil, tooltip: LF("Logické jádro CPU %@, poslední interval.", String(index + 1)))
        }
        cpu.update(data["cpu"] as? Double, tooltip: L("Vytížení všech jader CPU za poslední interval."))
        ram.update(data["ram"] as? Double, tooltip: L("Aktivní + wired + komprimované fyzické stránky / celková RAM. Nejde o indikátor tlaku na paměť."))
        gpu.update(data["gpu"] as? Double, tooltip: L("Vytížení GPU hlášené ovladačem; u více GPU maximum. Některé ovladače údaj neposkytují."))
        network.update(data["network"] as? Double, tooltip: data["networkExplanation"] as? String)
        if let date = lastUsage {
            let age = Int(Date().timeIntervalSince(date))
            if lastFetchFailed || age > 120 {
                updated.stringValue = LF("Limity: starší údaj (%@ min) · nelze obnovit", String(age / 60))
                updated.textColor = .systemOrange
            }
        }
    }

    func fetchUsage() {
        guard !isFetching else { return }
        isFetching = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var data: [String: Any]?
            if let binary = CodexUsage.codexBinary(),
               let payload = try? CodexUsage.read(binary: binary, onLaunch: { process in
                   DispatchQueue.main.async { self?.usageProcess = process }
               }) {
                data = CodexUsage.snapshot(payload, now: Date().timeIntervalSince1970)
            }
            let claude = ClaudeUsage.read()
            ClaudeHistory.record(claude, now: Date().timeIntervalSince1970)
            let history = ClaudeHistory.load()
            DispatchQueue.main.async { self?.applyClaude(claude, history: history) }
            var codexHistory: [UsageSample] = []
            if let data = data {
                CodexHistory.record(data, now: Date().timeIntervalSince1970)
                codexHistory = CodexHistory.load()
            }
            let codexTokens = CodexTokens.cachedTotals(now: Date().timeIntervalSince1970)
            let result = data
            let codexSamples = codexHistory
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isFetching = false
                self.usageProcess = nil
                guard let data = result else {
                    self.lastFetchFailed = true
                    self.updated.stringValue = self.lastUsage == nil ? L("Limity nejsou dostupné · místní výkon funguje") : L("Limity: starší údaj · nelze obnovit")
                    self.updated.textColor = .systemOrange
                    return
                }
                self.applyUsage(data, history: codexSamples, tokens: codexTokens)
            }
        }
    }

    func applyClaude(_ snap: ClaudeSnapshot, history: [UsageSample]) {
        let now = Date().timeIntervalSince1970
        claudeFive.samples = history
        claudeWeek.samples = history
        if let newest = history.last?.t {
            let age = now - newest
            if age <= 600 {
                claudeLive.stringValue = L("● Claude: aktivní")
                claudeLive.textColor = .systemGreen
            } else {
                claudeLive.stringValue = LF("○ Claude: neaktivní · poslední data před %@", ClaudeHistory.ageText(age))
                claudeLive.textColor = .tertiaryLabelColor
            }
        } else {
            claudeLive.stringValue = L("○ Claude: zatím žádná data")
            claudeLive.textColor = .tertiaryLabelColor
        }
        let age = snap.planObservedAt.map { now - $0 }
        let stale = age.map { $0 > ClaudeUsage.staleAfter } ?? true
        let formatter = DateFormatter()
        formatter.dateFormat = "d. M. HH:mm"
        func resetText(_ epoch: Double?) -> String {
            guard let epoch = epoch else { return L("Čas resetu není v lokálním zdroji Claude.") }
            return LF("Obnova: %@", formatter.string(from: Date(timeIntervalSince1970: epoch)))
        }
        claudeFive.setReset(snap.fiveHourResetsAt)
        claudeWeek.setReset(snap.weekResetsAt)
        claudeFive.update(snap.fiveHourUsed.map { 100 - $0 }, tooltip: resetText(snap.fiveHourResetsAt))
        claudeWeek.update(snap.weekUsed.map { 100 - $0 }, tooltip: resetText(snap.weekResetsAt))
        claudeFive.isStale = stale
        claudeWeek.isStale = stale
        if let five = snap.tokens5h, let week = snap.tokens7d {
            claudeTokens.stringValue = LF("Tokeny z Claude Code: 5 h %@ · 7 dní %@", ClaudeUsage.compact(five), ClaudeUsage.compact(week))
        } else {
            claudeTokens.stringValue = L("Tokeny z Claude Code: žádné místní záznamy")
        }
        guard let age = age else {
            claudeUpdated.stringValue = L("Claude: údaj není dostupný")
            claudeUpdated.textColor = .systemOrange
            return
        }
        var hints: [String] = []
        if !snap.fromStatusline { hints.append(L("Statusline Claude Code zatím nedodal data: spusťte `claude` v Terminálu.")) }
        if stale { hints.append(L("Obnovte: Claude → Nastavení → Využití.")) }
        if stale {
            claudeUpdated.stringValue = ([LF("Claude: starší údaj (%@ min)", String(Int(age / 60)))] + hints).joined(separator: "\n")
            claudeUpdated.textColor = .systemOrange
        } else {
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm"
            let source = snap.fromStatusline ? L("Claude Code (statusline)") : L("aplikace Claude")
            claudeUpdated.stringValue = ([LF("Claude: údaj z %@, %@", clock.string(from: Date(timeIntervalSince1970: snap.planObservedAt ?? now)), source)] + hints).joined(separator: "\n")
            claudeUpdated.textColor = hints.isEmpty ? .tertiaryLabelColor : .systemOrange
        }
    }

    func applyUsage(_ data: [String: Any], history: [UsageSample], tokens: CodexTokens.Totals?) {
        if let tokens = tokens {
            codexTokensLabel.stringValue = LF("Tokeny z Codex logů: 5 h %@ · 7 dní %@", ClaudeUsage.compact(tokens.fiveHour), ClaudeUsage.compact(tokens.week))
        } else {
            codexTokensLabel.stringValue = L("Tokeny z Codex logů: žádné záznamy")
        }
        quota.samples = history
        weekly.samples = history
        let buckets = data["buckets"] as? [[String: Any]] ?? []
        guard let bucket = buckets.first(where: { $0["id"] as? String == "codex" }) ?? buckets.first else {
            quota.update(nil); weekly.update(nil)
            updated.stringValue = L("API nevrátilo limity účtu")
            lastUsage = nil
            return
        }
        let windows = bucket["windows"] as? [[String: Any]] ?? []
        for (slot, row) in [("primary", quota), ("secondary", weekly)] {
            let window = windows.first { $0["slot"] as? String == slot }
            row.setReset(window?["resetsAt"] as? Double)
            let mins = window?["windowDurationMins"] as? Double
            let label: String
            if let mins = mins {
                label = mins == 10080 ? L("týden") : mins.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(mins / 60)) h" : "\(Int(mins)) min"
            } else { label = slot == "primary" ? L("krátkodobý limit") : L("dlouhodobý limit") }
            row.label.stringValue = LF("Zbývá · %@", label)
            var tooltip = L("Sdílený limit účtu Codex, ne tokeny této konverzace.")
            if let reset = window?["resetsAt"] as? Double {
                let formatter = DateFormatter()
                formatter.locale = Locale.current
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                tooltip += L(" Obnova: ") + formatter.string(from: Date(timeIntervalSince1970: reset))
            }
            if window?["resetPending"] as? Bool == true {
                row.update(nil, tooltip: tooltip + L(" Čeká se na nový stav po obnově."))
            } else { row.update(window?["remainingPercent"] as? Double, tooltip: tooltip) }
        }
        if let balance = bucket["creditBalance"] as? String {
            creditLabel.stringValue = LF("Kredity: %@", balance)
        } else { creditLabel.stringValue = L("Kredity: API neposkytuje zůstatek") }
        let restricted = bucket["spendControlReached"] as? Bool == true || bucket["limitReached"] as? Bool == true
        lastUsage = Date(timeIntervalSince1970: data["observedAt"] as? Double ?? Date().timeIntervalSince1970)
        lastFetchFailed = false
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        updated.stringValue = restricted ? L("Účet hlásí omezení čerpání") : LF("Limity %@ · Mac každé 2 s", formatter.string(from: lastUsage!))
        updated.textColor = restricted ? .systemOrange : .secondaryLabelColor
    }
}

// MARK: - Codex account limits (read-only, native; no Python runtime)
//
// Talks JSON-RPC over stdio to the local Codex app-server and calls only
// `account/rateLimits/read`. It never starts a thread or a turn, so it does not
// spend model tokens. Output keys match the reference adapter `scripts/usage_meter.py`.

enum CodexUsage {
    static let defaultTimeout: TimeInterval = 12
    static let extraSearchDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    static let chatGPTCandidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
    ]

    /// A Finder-launched app gets a minimal PATH, so Homebrew and npm locations are added explicitly.
    static func searchPath(environment: [String: String]) -> String {
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in extraSearchDirectories where !dirs.contains(dir) { dirs.append(dir) }
        return dirs.joined(separator: ":")
    }

    static func codexBinary(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        for dir in searchPath(environment: environment).split(separator: ":") {
            let path = "\(dir)/codex"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return chatGPTCandidates.first { fm.isExecutableFile(atPath: $0) }
    }

    static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Whitelists display fields. Account IDs, tokens and reset credits are never copied.
    static func snapshot(_ payload: [String: Any], now: Double) -> [String: Any] {
        var buckets = payload["rateLimitsByLimitId"] as? [String: Any] ?? [:]
        if buckets.isEmpty, let legacy = payload["rateLimits"] as? [String: Any] {
            buckets = ["codex": legacy]
        }
        var result: [String: Any] = ["source": "Codex account limits", "observedAt": now]
        var items: [[String: Any]] = []
        for key in buckets.keys.sorted() {
            guard let bucket = buckets[key] as? [String: Any] else { continue }
            var item: [String: Any] = [
                "id": key,
                "spendControlReached": bucket["spendControlReached"] as? Bool == true,
                "limitReached": isTruthy(bucket["rateLimitReachedType"]),
            ]
            if let credits = bucket["credits"] as? [String: Any], let balance = credits["balance"] {
                let text = balance as? String ?? (isBool(balance) ? "" : (balance as? NSNumber)?.stringValue ?? "")
                if let amount = Double(text), amount.isFinite, amount >= 0 { item["creditBalance"] = text }
            }
            var windows: [[String: Any]] = []
            for slot in ["primary", "secondary"] {
                guard let window = bucket[slot] as? [String: Any] else { continue }
                var row: [String: Any] = ["slot": slot, "resetPending": false]
                if let used = finiteNumber(window["usedPercent"]) {
                    row["remainingPercent"] = max(0, min(100, 100 - used))
                }
                if let mins = finiteNumber(window["windowDurationMins"]), mins > 0 {
                    row["windowDurationMins"] = mins
                }
                if let reset = finiteNumber(window["resetsAt"]), reset >= 0, reset <= 253402300799 {
                    row["resetsAt"] = reset
                    row["resetPending"] = reset <= now
                }
                windows.append(row)
            }
            item["windows"] = windows
            items.append(item)
        }
        result["buckets"] = items
        return result
    }

    static func isTruthy(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: return false
        case let text as String: return !text.isEmpty
        case let number as NSNumber: return number.doubleValue != 0
        default: return true
        }
    }

    /// Runs `codex app-server` for one read. Returns the raw `result` object of `account/rateLimits/read`.
    static func read(binary: String,
                     timeout: TimeInterval = defaultTimeout,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     onLaunch: ((Process) -> Void)? = nil) throws -> [String: Any] {
        signal(SIGPIPE, SIG_IGN)  // a closed pipe must surface as an error, not kill the app
        let link = try AppServerLink(binary: binary, environment: environment)
        onLaunch?(link.process)
        defer { link.shutdown() }
        let deadline = Date().addingTimeInterval(timeout)
        try link.send(["id": 1, "method": "initialize", "params": ["clientInfo": [
            "name": "usage_meter", "title": "Usage Meter", "version": "0.2.0"]]])
        _ = try link.response(1, deadline: deadline)
        try link.send(["method": "initialized", "params": [String: Any]()])
        try link.send(["id": 2, "method": "account/rateLimits/read"])
        return try link.response(2, deadline: deadline)
    }
}

struct ClaudeSnapshot {
    var planObservedAt: Double?
    var fiveHourUsed: Double?
    var weekUsed: Double?
    var fiveHourResetsAt: Double?
    var weekResetsAt: Double?
    var fromStatusline = false
    var tokens5h: Int?
    var tokens7d: Int?
}

/// Local, read-only Claude data. Limits come from the Claude app's own plan-usage file
/// (`fh` = 5-hour window, `sd` = 7-day window, both "used" percent). Tokens come from
/// Claude Code session logs. Neither source is the official live limit API.
enum ClaudeUsage {
    static let staleAfter: TimeInterval = 3600
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let planFile = home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    static let projects = home.appendingPathComponent(".claude/projects")
    static let timeFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plainTimeFormatter = ISO8601DateFormatter()

    static func read(now: Date = Date(), planFile: URL = ClaudeUsage.planFile, projects: URL = ClaudeUsage.projects) -> ClaudeSnapshot {
        var snap = ClaudeSnapshot()
        if let live = ClaudeStatusline.freshLimits(now: now.timeIntervalSince1970) {
            snap.planObservedAt = live.observedAt
            snap.fiveHourUsed = live.fiveHourUsed
            snap.weekUsed = live.weekUsed
            snap.fiveHourResetsAt = live.fiveHourResetsAt
            snap.weekResetsAt = live.weekResetsAt
            snap.fromStatusline = true
        } else if let plan = planSnapshot(url: planFile) {
            snap.planObservedAt = plan.time
            snap.fiveHourUsed = plan.fiveHour
            snap.weekUsed = plan.week
        }
        if let totals = tokenTotals(root: projects, now: now.timeIntervalSince1970) {
            snap.tokens5h = totals.fiveHour
            snap.tokens7d = totals.week
        }
        return snap
    }

    /// Takes the newest sample. Values outside 0...100 are dropped, not clamped.
    static func planSnapshot(url: URL) -> (time: Double, fiveHour: Double?, week: Double?)? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["version"] as? NSNumber)?.intValue == 2,
              let samples = root["samples"] as? [[String: Any]] else { return nil }
        var newest: (time: Double, usage: [String: Any])?
        for sample in samples {
            guard var time = CodexUsage.finiteNumber(sample["t"]) else { continue }
            if time > 1e11 { time /= 1000 }
            if newest == nil || time > newest!.time {
                newest = (time, sample["u"] as? [String: Any] ?? [:])
            }
        }
        guard let latest = newest else { return nil }
        func percent(_ key: String) -> Double? {
            guard let value = CodexUsage.finiteNumber(latest.usage[key]), value >= 0, value <= 100 else { return nil }
            return value
        }
        return (latest.time, percent("fh"), percent("sd"))
    }

    /// Sums tokens per message id (streamed records repeat the id, the last record wins).
    static func tokenTotals(root: URL, now: Double) -> (fiveHour: Int, week: Int)? {
        guard FileManager.default.fileExists(atPath: root.path),
              let walker = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        let weekAgo = now - 7 * 24 * 3600
        var perMessage: [String: (time: Double, tokens: Int)] = [:]
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            guard modified >= weekAgo, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let id = message["id"] as? String,
                      let stamp = object["timestamp"] as? String,
                      let time = parseTime(stamp) else { continue }
                let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .reduce(0) { $0 + Int(CodexUsage.finiteNumber(usage[$1]) ?? 0) }
                perMessage[id] = (time, tokens)
            }
        }
        var five = 0, week = 0
        for entry in perMessage.values where entry.time >= weekAgo {
            week += entry.tokens
            if entry.time >= now - 5 * 3600 { five += entry.tokens }
        }
        return (five, week)
    }

    static func parseTime(_ text: String) -> Double? {
        (timeFormatter.date(from: text) ?? plainTimeFormatter.date(from: text))?.timeIntervalSince1970
    }

    static func compact(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1f M", Double(count) / 1e6) : String(format: "%.0f k", Double(count) / 1e3)
    }
}

/// What Codex is doing right now, read from the newest session log (`~/.codex/sessions`). Local only, no network.
enum CodexActivity {
    enum Kind: String {
        case running, done, waiting, error, info
    }

    struct Step {
        let time: Double
        let kind: Kind
        let text: String
    }

    struct Session {
        let id: String
        let state: String          // "running", "done", "aborted", "idle"
        let updated: Double
        let steps: [Step]
    }

    static var sessions: URL {
        if let override = ProcessInfo.processInfo.environment["USAGE_METER_TEST_CODEX"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// Reads the newest log of the last day. Only the tail of the file is parsed, so this stays cheap every two seconds.
    static func latest(root: URL = sessions, now: Double) -> Session? {
        guard let walker = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        var newest: (url: URL, modified: Double)?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            if now - modified > 24 * 3600 { continue }
            if newest == nil || modified > newest!.modified { newest = (url, modified) }
        }
        guard let file = newest, let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: 0x0A)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // the first line may be cut in the middle
        return parse(lines: lines, id: sessionID(file.url), modified: file.modified, now: now)
    }

    /// The session id is the UUID at the end of `rollout-<time>-<uuid>.jsonl`.
    static func sessionID(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.count >= 36 ? String(stem.suffix(36)) : stem
    }

    static func parse(lines: [Data.SubSequence], id: String, modified: Double, now: Double) -> Session {
        var steps: [Step] = []
        var pending: [String: Int] = [:]            // call id -> index of its running step
        var lastStarted: Double?, lastFinished: Double?, aborted = false
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let time = ClaudeUsage.parseTime(object["timestamp"] as? String ?? "") ?? modified
            let payload = object["payload"] as? [String: Any] ?? [:]
            let kind = object["type"] as? String ?? ""
            let type = payload["type"] as? String ?? ""
            switch (kind, type) {
            case ("event_msg", "task_started"):
                lastStarted = time
                steps.append(Step(time: time, kind: .running, text: "Zadání úlohy"))
            case ("event_msg", "task_complete"):
                lastFinished = time
                steps.append(Step(time: time, kind: .done, text: "Úloha dokončena"))
            case ("event_msg", "turn_aborted"):
                lastFinished = time
                aborted = true
                steps.append(Step(time: time, kind: .error, text: "Přerušeno"))
            case ("event_msg", let t) where t.lowercased().contains("error"):
                steps.append(Step(time: time, kind: .error, text: short(payload["message"] as? String ?? t)))
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
                let name = payload["name"] as? String ?? "nástroj"
                let detail = short(commandText(payload["arguments"] ?? payload["input"]))
                if let callID = payload["call_id"] as? String { pending[callID] = steps.count }
                steps.append(Step(time: time, kind: .running, text: detail.isEmpty ? name : "\(name): \(detail)"))
            case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
                if let callID = payload["call_id"] as? String, let index = pending[callID] {
                    steps[index] = Step(time: steps[index].time, kind: .done, text: steps[index].text)
                    pending[callID] = nil
                }
            case ("response_item", "agent_message"), ("response_item", "message"):
                if (payload["role"] as? String) == "user" { continue }
                let text = (payload["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ")
                    ?? payload["message"] as? String ?? ""
                // Messages between Codex agents are internal bookkeeping, not what the user sees.
                if !text.isEmpty, !text.hasPrefix("Message Type:") { steps.append(Step(time: time, kind: .info, text: short(text))) }
            default:
                break
            }
        }
        // Calls still without output: waiting for a result (possibly an approval). This is an estimate.
        for (_, index) in pending where now - steps[index].time > 20 {
            steps[index] = Step(time: steps[index].time, kind: .waiting, text: steps[index].text)
        }
        let state: String
        if aborted, (lastFinished ?? 0) >= (lastStarted ?? 0) { state = "aborted" }
        else if let started = lastStarted, (lastFinished ?? 0) < started { state = now - modified < 120 ? "running" : "idle" }
        else if lastFinished != nil { state = "done" }
        else { state = "idle" }
        return Session(id: id, state: state, updated: modified, steps: Array(steps.suffix(12)))
    }

    static func commandText(_ value: Any?) -> String {
        if let text = value as? String {
            if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return commandText(object)
            }
            return text
        }
        if let object = value as? [String: Any] {
            return (object["cmd"] as? String) ?? (object["command"] as? String) ?? (object["path"] as? String) ?? ""
        }
        return ""
    }

    static func short(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return oneLine.count > 90 ? String(oneLine.prefix(90)) + "…" : oneLine
    }
}

/// Panel with what Codex is doing right now, updated every two seconds while it is open.
final class CodexActivityWindow: NSObject {
    private let panel: NSPanel
    private let stateLabel = NSTextField(labelWithString: "")
    private let idLabel = NSTextField(labelWithString: "")
    private let steps = NSStackView()
    private var timer: Timer?
    private var sessionID = ""
    private let openApp = NSButton(title: "", target: nil, action: nil)
    private let openTerminal = NSButton(title: "", target: nil, action: nil)

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = L("Codex · aktivita")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        let root = NSView()
        panel.contentView = root
        stateLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        idLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        idLabel.textColor = .secondaryLabelColor
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 4
        openApp.title = L("Otevřít v Codexu")
        openApp.bezelStyle = .rounded
        openApp.target = self
        openApp.action = #selector(openInCodex)
        openTerminal.title = L("Otevřít v Terminálu")
        openTerminal.bezelStyle = .rounded
        openTerminal.target = self
        openTerminal.action = #selector(openInTerminal)
        let buttons = NSStackView(views: [openApp, openTerminal])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [stateLabel, idLabel, steps, NSView(), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            steps.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28)
        ])
        panel.setContentSize(NSSize(width: 380, height: 360))
    }

    func show() {
        refresh()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let session = CodexActivity.latest(now: Date().timeIntervalSince1970)
            DispatchQueue.main.async { self?.apply(session) }
        }
    }

    private func apply(_ session: CodexActivity.Session?) {
        guard let session = session else {
            stateLabel.stringValue = L("Codex: zatím žádná aktivita")
            idLabel.stringValue = ""
            sessionID = ""
            steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
            openTerminal.isEnabled = false
            return
        }
        sessionID = session.id
        openTerminal.isEnabled = true
        stateLabel.stringValue = [
            "running": L("● Běží"), "done": L("✓ Dokončeno"),
            "aborted": L("✖ Přerušeno"), "idle": L("○ Nečinný")
        ][session.state] ?? session.state
        stateLabel.textColor = session.state == "aborted" ? .systemRed : session.state == "running" ? .systemGreen : .labelColor
        idLabel.stringValue = session.id
        steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for step in session.steps {
            let line = NSTextField(labelWithString: "")
            line.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            line.lineBreakMode = .byTruncatingTail
            line.maximumNumberOfLines = 2
            line.preferredMaxLayoutWidth = 320
            line.attributedStringValue = NSAttributedString(string: "\(icon(step.kind))  \(step.text)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: color(step.kind)])
            steps.addArrangedSubview(line)
        }
    }

    private func icon(_ kind: CodexActivity.Kind) -> String {
        switch kind {
        case .running: return "●"
        case .waiting: return "◐"
        case .error: return "✖"
        case .done: return "✓"
        case .info: return "•"
        }
    }

    private func color(_ kind: CodexActivity.Kind) -> NSColor {
        switch kind {
        case .running: return .systemGreen
        case .waiting: return .systemYellow
        case .error: return .systemRed
        case .done: return .tertiaryLabelColor
        case .info: return .labelColor
        }
    }

    @objc private func openInCodex() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            stateLabel.stringValue = L("Aplikace Codex nebyla nalezena.")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// Opens Terminal and runs `codex resume <id>`. The command is also copied, so it can be pasted if Terminal refuses.
    @objc private func openInTerminal() {
        guard !sessionID.isEmpty else { return }
        let command = "codex resume \(sessionID)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let script = NSAppleScript(source: "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if error != nil { stateLabel.stringValue = L("Příkaz je zkopírován: vložte ho do Terminálu.") }
    }
}

/// Token totals from the Codex CLI session logs (`~/.codex/sessions`). These are local token counts, not the plan limit.
/// Counted per `last_token_usage.total_tokens` of each `token_count` event; events repeated across files count once.
enum CodexTokens {
    struct Totals {
        let fiveHour: Int
        let week: Int
    }

    static var sessions: URL {
        if let override = ProcessInfo.processInfo.environment["USAGE_METER_TEST_CODEX"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private static var cache: (computed: Double, totals: Totals?)?
    static let cacheSeconds: Double = 300

    /// Only called from the refresh queue; the cache avoids reading the logs every 30 seconds.
    static func cachedTotals(now: Double) -> Totals? {
        if let cache = cache, now - cache.computed < cacheSeconds { return cache.totals }
        let totals = totals(root: sessions, now: now)
        cache = (now, totals)
        return totals
    }

    static func totals(root: URL, now: Double) -> Totals? {
        guard FileManager.default.fileExists(atPath: root.path),
              let walker = FileManager.default.enumerator(at: root,
                  includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        let weekAgo = now - 7 * 24 * 3600
        let fiveAgo = now - 5 * 3600
        let marker = Data("token_count".utf8)
        var seen = Set<String>()
        var five = 0, week = 0
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            guard modified >= weekAgo, let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) where line.range(of: marker) != nil {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let stamp = object["timestamp"] as? String,
                      let time = ClaudeUsage.parseTime(stamp),
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let tokens = CodexUsage.finiteNumber(last["total_tokens"]) else { continue }
                guard seen.insert("\(stamp)|\(Int(tokens))").inserted else { continue }
                if time >= weekAgo { week += Int(tokens) }
                if time >= fiveAgo { five += Int(tokens) }
            }
        }
        return Totals(fiveHour: five, week: week)
    }
}

enum CodexUsageError: Error {
    case unavailable(String)
}

/// One app-server child process with a thread-safe queue of decoded JSON messages.
final class AppServerLink {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()
    private var messages: [[String: Any]] = []
    private var buffer = Data()
    private var closed = false

    init(binary: String, environment: [String: String]) throws {
        var env = environment
        env["PATH"] = CodexUsage.searchPath(environment: environment)
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--stdio", "--disable", "hooks"]
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { self?.finish() } else { self?.receive(chunk) }
        }
        do {
            try process.run()
        } catch {
            throw CodexUsageError.unavailable("launch")
        }
    }

    private func receive(_ chunk: Data) {
        condition.lock()
        defer { condition.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard line.count <= 1_000_000,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  messages.count < 128 else { continue }
            messages.append(object)
        }
        condition.broadcast()
    }

    private func finish() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw CodexUsageError.unavailable("write")
        }
    }

    /// Returns the `result` of the response with `id`. Server-initiated requests get an error reply.
    func response(_ id: Int, deadline: Date) throws -> [String: Any] {
        while true {
            condition.lock()
            while messages.isEmpty && !closed {
                if !condition.wait(until: deadline) { break }
            }
            guard let message = messages.first else {
                let reason = closed ? "closed" : "timeout"
                condition.unlock()
                throw CodexUsageError.unavailable(reason)
            }
            messages.removeFirst()
            condition.unlock()

            if let requestID = message["id"], message["method"] != nil {
                try send(["id": requestID, "error": ["code": -32601,
                    "message": "Usage Meter supports read-only usage queries"]])
                continue
            }
            guard message["method"] == nil, (message["id"] as? NSNumber)?.intValue == id else { continue }
            if message["error"] != nil {
                // Raw server errors can contain private details; they are never reported.
                throw CodexUsageError.unavailable("server-error")
            }
            guard let result = message["result"] as? [String: Any] else {
                throw CodexUsageError.unavailable("invalid-response")
            }
            return result
        }
    }

    func shutdown() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let stop = Date().addingTimeInterval(2)
        while process.isRunning && Date() < stop { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? output.fileHandleForReading.close()
    }
}

// Test hooks used by tests/test_native_adapter.py. They do not affect normal launch.
if CommandLine.arguments.count >= 2 && CommandLine.arguments[1] == "--usage-find-codex" {
    if let path = CodexUsage.codexBinary() { print(path); exit(0) }
    exit(1)
}
if CommandLine.arguments.count >= 5 && CommandLine.arguments[1] == "--claude-check" {
    let args = CommandLine.arguments
    let snap = ClaudeUsage.read(now: Date(timeIntervalSince1970: Double(args[4]) ?? 0),
                                planFile: URL(fileURLWithPath: args[2]), projects: URL(fileURLWithPath: args[3]))
    var out: [String: Any] = [:]
    if let v = snap.planObservedAt { out["planObservedAt"] = v }
    if let v = snap.fiveHourUsed { out["fiveHourUsed"] = v }
    if let v = snap.weekUsed { out["weekUsed"] = v }
    if let v = snap.fiveHourResetsAt { out["fiveHourResetsAt"] = v }
    if let v = snap.weekResetsAt { out["weekResetsAt"] = v }
    if let v = snap.tokens5h { out["tokens5h"] = v }
    if let v = snap.tokens7d { out["tokens7d"] = v }
    print(String(data: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}
if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--usage-check" {
    let timeout = CommandLine.arguments.count >= 4 ? Double(CommandLine.arguments[3]) ?? CodexUsage.defaultTimeout : CodexUsage.defaultTimeout
    do {
        let payload = try CodexUsage.read(binary: CommandLine.arguments[2], timeout: timeout)
        let data = CodexUsage.snapshot(payload, now: Date().timeIntervalSince1970)
        print(String(data: try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), encoding: .utf8)!)
        exit(0)
    } catch {
        print("{\"status\":\"unavailable\"}")
        exit(1)
    }
}

// MARK: - Usage history (7 days, local) and the gauge that shows it

struct UsageSample: Codable {
    let t: Double
    let five: Double?
    let week: Double?
}

/// Local history per source. A sample is skipped when it repeats the newest reading,
/// or when the values did not change for five minutes.
enum UsageHistory {
    static let keepSeconds: Double = 7 * 24 * 3600
    static let maxSamples = 4000

    static func load(_ name: String) -> [UsageSample] {
        guard let data = try? Data(contentsOf: AppSupport.directory.appendingPathComponent(name)) else { return [] }
        return ((try? JSONDecoder().decode([UsageSample].self, from: data)) ?? []).sorted { $0.t < $1.t }
    }

    static func append(_ name: String, _ sample: UsageSample, now: Double) {
        var items = load(name)
        if let last = items.last {
            if last.t == sample.t { return }
            if last.five == sample.five && last.week == sample.week && sample.t - last.t < 300 { return }
        }
        items.append(sample)
        items = items.filter { now - $0.t <= keepSeconds }
        if items.count > maxSamples { items.removeFirst(items.count - maxSamples) }
        if let data = try? JSONEncoder().encode(items) {
            try? AppSupport.writeAtomically(data, to: AppSupport.directory.appendingPathComponent(name))
        }
    }

    static func ageText(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 { return "\(minutes / 60) h" }
        return "\(minutes / 1440) d"
    }
}

enum ClaudeHistory {
    static let file = "claude-history.json"

    /// Stores a sample only when the source reports a new observation time.
    static func record(_ snap: ClaudeSnapshot, now: Double) {
        guard let observed = snap.planObservedAt else { return }
        UsageHistory.append(file, UsageSample(t: observed, five: snap.fiveHourUsed, week: snap.weekUsed), now: now)
    }

    static func load() -> [UsageSample] { UsageHistory.load(file) }
    static func ageText(_ seconds: Double) -> String { UsageHistory.ageText(seconds) }
}

enum CodexHistory {
    static let file = "codex-history.json"

    /// Used percent per window, from the remaining percent of the Codex snapshot.
    static func record(_ data: [String: Any], now: Double) {
        let buckets = data["buckets"] as? [[String: Any]] ?? []
        guard let bucket = buckets.first(where: { $0["id"] as? String == "codex" }) ?? buckets.first else { return }
        let windows = bucket["windows"] as? [[String: Any]] ?? []
        func used(_ slot: String) -> Double? {
            guard let window = windows.first(where: { $0["slot"] as? String == slot }),
                  let remaining = CodexUsage.finiteNumber(window["remainingPercent"]) else { return nil }
            return 100 - remaining
        }
        let five = used("primary"), week = used("secondary")
        guard five != nil || week != nil else { return }
        UsageHistory.append(file, UsageSample(t: now, five: five, week: week), now: now)
    }

    static func load() -> [UsageSample] { UsageHistory.load(file) }
}

enum GaugeMode: String {
    case bar, curve
}

/// Bar mode: three zones (green low, orange medium, red high use) with an arrow at the current use.
/// Curve mode: the same value over the last 24 hours. A click switches between the two.
final class UsageGauge: NSView {
    var mode: GaugeMode = .bar { didSet { needsDisplay = true } }
    var used: Double? { didSet { needsDisplay = true } }
    var samples: [UsageSample] = [] { didSet { needsDisplay = true } }
    var series: KeyPath<UsageSample, Double?> = \.five
    var tint: NSColor = .controlAccentColor
    var now: Double = Date().timeIntervalSince1970 { didSet { needsDisplay = true } }
    var onToggle: (() -> Void)?
    private let span: Double = 24 * 3600

    override func mouseDown(with event: NSEvent) { onToggle?() }

    override func draw(_ dirtyRect: NSRect) {
        switch mode {
        case .bar: drawBar()
        case .curve: drawCurve()
        }
    }

    private func drawBar() {
        let track = NSRect(x: 0, y: 2, width: bounds.width, height: max(4, bounds.height - 6))
        let zones: [(from: Double, to: Double, color: NSColor)] = [(0, 50, .systemGreen), (50, 85, .systemOrange), (85, 100, .systemRed)]
        for zone in zones {
            let rect = NSRect(x: track.minX + track.width * CGFloat(zone.from / 100), y: track.minY,
                              width: track.width * CGFloat((zone.to - zone.from) / 100), height: track.height)
            zone.color.withAlphaComponent(used == nil ? 0.25 : 0.85).setFill()
            rect.fill()
        }
        guard let used = used, used.isFinite else { return }
        let x = track.minX + track.width * CGFloat(max(0, min(100, used)) / 100)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: x - 4, y: bounds.height))
        arrow.line(to: NSPoint(x: x + 4, y: bounds.height))
        arrow.line(to: NSPoint(x: x, y: track.maxY))
        NSColor.labelColor.setFill()
        arrow.fill()
    }

    private func drawCurve() {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let start = now - span
        func point(_ t: Double, _ value: Double) -> NSPoint {
            NSPoint(x: bounds.width * CGFloat((t - start) / span),
                    y: 3 + (bounds.height - 6) * CGFloat(max(0, min(100, value)) / 100))
        }
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        var previous: UsageSample?
        var points: [NSPoint] = []
        for sample in samples where sample.t >= start && sample.t <= now + 60 {
            guard let value = sample[keyPath: series] else { previous = nil; continue }
            let p = point(sample.t, value)
            points.append(p)
            if let before = previous, sample.t - before.t <= 1800 { path.line(to: p) } else { path.move(to: p) }
            previous = sample
        }
        tint.setStroke()
        path.stroke()
        // A single reading has no line yet, so each point also gets a dot.
        tint.setFill()
        for p in points {
            NSBezierPath(ovalIn: NSRect(x: p.x - 1.8, y: p.y - 1.8, width: 3.6, height: 3.6)).fill()
        }
    }
}

/// "45 min", "2 h 15 min", "3 d 4 h" for a remaining time in seconds.
func durationText(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 60 { return LF("%@ min", String(minutes)) }
    if minutes < 24 * 60 { return LF("%@ h %@ min", String(minutes / 60), String(minutes % 60)) }
    return LF("%@ d %@ h", String(minutes / 1440), String((minutes % 1440) / 60))
}

/// Title, remaining value and a gauge. The gauge's mode is remembered per key across launches.
final class GaugeRow: NSView {
    let label = NSTextField(labelWithString: "")
    let value = NSTextField(labelWithString: "—")
    private let gauge = UsageGauge()
    private let resetLabel = NSTextField(labelWithString: "")
    private let key: String
    private var heightConstraint: NSLayoutConstraint!
    var onChange: (() -> Void)?

    init(_ title: String, key: String, tint: NSColor, series: KeyPath<UsageSample, Double?>) {
        self.key = key
        super.init(frame: .zero)
        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        value.alignment = .right
        gauge.tint = tint
        gauge.series = series
        gauge.mode = GaugeRow.savedMode(key)
        gauge.onToggle = { [weak self] in self?.toggle() }
        gauge.setAccessibilityLabel(title)
        let line = NSStackView(views: [label, NSView(), value])
        line.orientation = .horizontal
        resetLabel.font = .systemFont(ofSize: 9)
        resetLabel.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [line, gauge, resetLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        heightConstraint = gauge.heightAnchor.constraint(equalToConstant: 16)
        heightConstraint.isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalTo: stack.widthAnchor), gauge.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        applyHeight()
    }

    required init?(coder: NSCoder) { fatalError() }

    var samples: [UsageSample] = [] {
        didSet {
            gauge.samples = samples
            gauge.now = Date().timeIntervalSince1970
        }
    }

    /// `remaining` is shown as text; the gauge shows the used share (100 - remaining).
    func update(_ remaining: Double?, tooltip: String? = nil) {
        if let remaining = remaining, remaining.isFinite {
            let shown = max(0, min(100, remaining))
            gauge.used = 100 - shown
            value.stringValue = String(format: "%.0f %%", shown)
            value.textColor = shown < 15 ? .systemOrange : .labelColor
        } else {
            gauge.used = nil
            value.stringValue = "—"
            value.textColor = .secondaryLabelColor
        }
        toolTip = tooltip
    }

    /// Shows how long until the window resets, e.g. "Obnova za 2 h 15 min".
    func setReset(_ resetsAt: Double?) {
        guard let resetsAt = resetsAt else { resetLabel.stringValue = ""; return }
        let remaining = resetsAt - Date().timeIntervalSince1970
        resetLabel.stringValue = remaining > 0 ? LF("Obnova za %@", durationText(remaining)) : ""
    }

    /// Alpha is used to show stale data.
    var isStale: Bool = false { didSet { alphaValue = isStale ? 0.5 : 1 } }

    static func savedMode(_ key: String) -> GaugeMode {
        GaugeMode(rawValue: UserDefaults.standard.string(forKey: "gauge.\(key)") ?? "") ?? .bar
    }

    private func toggle() {
        gauge.mode = gauge.mode == .bar ? .curve : .bar
        UserDefaults.standard.set(gauge.mode.rawValue, forKey: "gauge.\(key)")
        applyHeight()
        onChange?()
    }

    private func applyHeight() {
        heightConstraint.constant = gauge.mode == .bar ? 16 : 44
    }
}

// MARK: - Claude Code status line (official hook; no cookies, no tokens, no network)
//
// Claude Code runs `statusLine.command` after each assistant message and passes session JSON on stdin.
// The JSON contains `rate_limits.five_hour` and `rate_limits.seven_day` with `used_percentage` and `resets_at`.
// This mode stores only those four numbers per window and never copies cwd, transcript paths or ids.

enum AppSupport {
    /// `USAGE_METER_TEST_SUPPORT` redirects storage in tests only.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["USAGE_METER_TEST_SUPPORT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Usage Meter Pure", isDirectory: true)
    }

    /// Writes atomically, follows symlinks (dotfile setups), keeps the existing permissions, and uses 0600 for new files.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]) as? NSNumber
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: existing?.intValue ?? 0o600], ofItemAtPath: target.path)
    }
}

enum ClaudeStatusline {
    static var file: URL { AppSupport.directory.appendingPathComponent("claude-statusline.json") }
    static var configFile: URL { AppSupport.directory.appendingPathComponent("claude-setup.json") }
    static let maxAge: TimeInterval = 3600

    struct Limits {
        let observedAt: Double
        let fiveHourUsed: Double?
        let weekUsed: Double?
        let fiveHourResetsAt: Double?
        let weekResetsAt: Double?
    }

    /// Entry point for `UsageMeter --statusline`. Always exits 0 so Claude Code never shows an error.
    static func run(stdin: Data) -> Int32 {
        if let json = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
           let limits = json["rate_limits"] as? [String: Any] {
            save(limits, now: Date().timeIntervalSince1970)
        }
        guard let previous = loadConfig()?["previousCommand"] as? String, !previous.isEmpty else { return 0 }
        return runChained(previous, stdin: stdin)
    }

    static func save(_ limits: [String: Any], now: Double) {
        func window(_ key: String) -> [String: Any] {
            guard let node = limits[key] as? [String: Any] else { return [:] }
            var out: [String: Any] = [:]
            if let used = CodexUsage.finiteNumber(node["used_percentage"]), used >= 0, used <= 100 {
                out["usedPercent"] = used
            }
            if var reset = CodexUsage.finiteNumber(node["resets_at"]), reset > 0 {
                if reset > 1e11 { reset /= 1000 }
                out["resetsAt"] = reset
            }
            return out
        }
        // A payload may carry only one window; keep the previously stored value for the other.
        var record: [String: Any] = ["observedAt": now]
        let previous = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        for (name, key) in [("fiveHour", "five_hour"), ("sevenDay", "seven_day")] {
            let fresh = window(key)
            record[name] = fresh.isEmpty ? (previous[name] as? [String: Any] ?? [:]) : fresh
        }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        try? AppSupport.writeAtomically(data, to: file)
    }

    /// Returns the stored limits only when they are recent and their reset time is still in the future.
    static func freshLimits(now: Double) -> Limits? {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let observed = CodexUsage.finiteNumber(root["observedAt"]),
              now - observed <= maxAge else { return nil }
        func values(_ key: String) -> (used: Double?, reset: Double?) {
            let node = root[key] as? [String: Any] ?? [:]
            let reset = CodexUsage.finiteNumber(node["resetsAt"])
            let used = CodexUsage.finiteNumber(node["usedPercent"])
            // After a window has reset, the old percentage no longer applies.
            if let reset = reset, reset <= now { return (nil, nil) }
            return (used, reset)
        }
        let five = values("fiveHour")
        let week = values("sevenDay")
        // A recent record is authoritative even when both windows have reset: the values are then unknown, not old.
        return Limits(observedAt: observed, fiveHourUsed: five.used, weekUsed: week.used,
                      fiveHourResetsAt: five.reset, weekResetsAt: week.reset)
    }

    static func loadConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configFile) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func runChained(_ command: String, stdin: Data) -> Int32 {
        signal(SIGPIPE, SIG_IGN)  // a child that stops reading must not kill the status line
        final class Box { var output = Data() }
        let box = Box()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return 0 }
        let finished = DispatchSemaphore(value: 0)
        // Reading and writing happen off the main thread so the 5 s deadline below always applies.
        DispatchQueue.global().async {
            box.output = output.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        DispatchQueue.global().async {
            try? input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
        }
        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
        }
        FileHandle.standardOutput.write(box.output)
        return 0
    }
}

enum ClaudeSetupState {
    case installed, alreadyInstalled, claudeNotFound, unreadable, removed

    var label: String {
        switch self {
        case .installed: return L("Claude Code: statusline připojen automaticky.")
        case .alreadyInstalled: return L("Claude Code: statusline je připojen.")
        case .claudeNotFound: return L("Claude Code není nainstalován. Statusline se připojí po instalaci.")
        case .unreadable: return L("Claude Code: nastavení nejde bezpečně upravit, zůstává beze změny.")
        case .removed: return L("Claude Code: statusline odpojen.")
        }
    }
}

/// Connects Claude Code to this app by writing the `statusLine` key in `~/.claude/settings.json`.
/// Keeps every other key, backs up the file once, and chains any status line the user already had.
enum ClaudeSetup {
    static var claudeDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["USAGE_METER_TEST_CLAUDE"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }
    static var settingsFile: URL { claudeDirectory.appendingPathComponent("settings.json") }
    static var backupFile: URL { claudeDirectory.appendingPathComponent("settings.json.usage-meter-backup.json") }

    /// Single quotes stop the shell from expanding `$`, backticks or `$(...)` in the app path.
    static func command(for binary: String) -> String {
        "'" + binary.replacingOccurrences(of: "'", with: "'\\''") + "' --statusline"
    }

    /// Only our own app binary inside a bundle counts, so a user's `echo UsageMeter --statusline` is not replaced.
    static func isOurs(_ command: String?) -> Bool {
        guard let command = command else { return false }
        return command.hasSuffix(" --statusline") && command.contains(".app/Contents/MacOS/UsageMeter")
    }

    static func install(binary: String) -> ClaudeSetupState {
        guard binary.hasPrefix("/"), binary.hasSuffix("/UsageMeter") else { return .unreadable }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: claudeDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .claudeNotFound
        }
        var settings: [String: Any] = [:]
        let hadSettings = FileManager.default.fileExists(atPath: settingsFile.path)
        if hadSettings {
            guard let data = try? Data(contentsOf: settingsFile),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
            settings = object
        }
        let ours = command(for: binary)
        var config = ClaudeStatusline.loadConfig() ?? [:]
        let current = settings["statusLine"] as? [String: Any]
        let currentCommand = current?["command"] as? String
        if currentCommand == ours && config["installedCommand"] as? String == ours {
            return .alreadyInstalled
        }
        if !isOurs(currentCommand) {
            // Remember the user's own status line so it keeps running, and so uninstall can restore it.
            config["previousStatusLine"] = current as Any?
            config["previousCommand"] = currentCommand as Any?
        }
        if hadSettings && !FileManager.default.fileExists(atPath: backupFile.path) {
            // Without a backup we do not touch the user's settings at all.
            do { try FileManager.default.copyItem(at: settingsFile, to: backupFile) } catch { return .unreadable }
        }
        // Keep every other field of the user's status line (padding, refreshInterval, ...); change only type and command.
        var line = current ?? [:]
        line["type"] = "command"
        line["command"] = ours
        settings["statusLine"] = line
        config["installedCommand"] = ours
        // Config first: if it cannot be saved, the previous status line is not lost by changing settings.
        guard let configData = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              (try? AppSupport.writeAtomically(configData, to: ClaudeStatusline.configFile)) != nil else { return .unreadable }
        guard write(settings) else { return .unreadable }
        return currentCommand == ours ? .alreadyInstalled : .installed
    }

    /// Restores the user's previous status line, or removes the key if there was none.
    static func uninstall() -> ClaudeSetupState {
        let config = ClaudeStatusline.loadConfig() ?? [:]
        if let data = try? Data(contentsOf: settingsFile) {
            guard var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
            if isOurs((settings["statusLine"] as? [String: Any])?["command"] as? String) {
                if let previous = config["previousStatusLine"] as? [String: Any] {
                    settings["statusLine"] = previous
                } else {
                    settings.removeValue(forKey: "statusLine")
                }
                // Keep the saved state until the restore has been written.
                guard write(settings) else { return .unreadable }
            }
        }
        try? FileManager.default.removeItem(at: ClaudeStatusline.configFile)
        try? FileManager.default.removeItem(at: ClaudeStatusline.file)
        return .removed
    }

    static func write(_ settings: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? AppSupport.writeAtomically(data, to: settingsFile)) != nil
    }
}

if CommandLine.arguments.count >= 2 && CommandLine.arguments[1] == "--statusline" {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    exit(ClaudeStatusline.run(stdin: input))
}
if CommandLine.arguments.count >= 5 && CommandLine.arguments[1] == "--claude-history" {
    // Test hook: record one reading from the given sources, then print the stored samples.
    let args = CommandLine.arguments
    let now = Double(args[4]) ?? 0
    let snap = ClaudeUsage.read(now: Date(timeIntervalSince1970: now),
                                planFile: URL(fileURLWithPath: args[2]), projects: URL(fileURLWithPath: args[3]))
    ClaudeHistory.record(snap, now: now)
    let items = ClaudeHistory.load().map { ["t": $0.t, "five": $0.five as Any, "week": $0.week as Any] as [String: Any] }
    print(String(data: try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}
if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "--codex-history" {
    // Test hook: record one Codex reading (account/rateLimits/read result in a file), then print stored samples.
    let args = CommandLine.arguments
    let now = Double(args[3]) ?? 0
    let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as? [String: Any] ?? [:]
    let data = CodexUsage.snapshot(payload, now: now)
    CodexHistory.record(data, now: now)
    let items = CodexHistory.load().map { ["t": $0.t, "five": $0.five as Any, "week": $0.week as Any] as [String: Any] }
    print(String(data: try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}
if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "--codex-activity" {
    let args = CommandLine.arguments
    let now = Double(args[3]) ?? 0
    var out: [String: Any] = [:]
    if let session = CodexActivity.latest(root: URL(fileURLWithPath: args[2]), now: now) {
        out["id"] = session.id
        out["state"] = session.state
        out["steps"] = session.steps.map { ["kind": $0.kind.rawValue, "text": $0.text] }
    }
    print(String(data: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}
if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "--codex-tokens" {
    let args = CommandLine.arguments
    let totals = CodexTokens.totals(root: URL(fileURLWithPath: args[2]), now: Double(args[3]) ?? 0)
    let out: [String: Any] = ["fiveHour": totals?.fiveHour ?? -1, "week": totals?.week ?? -1]
    print(String(data: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}
if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--claude-setup" {
    let state: ClaudeSetupState = CommandLine.arguments[2] == "uninstall" ? ClaudeSetup.uninstall()
        : ClaudeSetup.install(binary: CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : "")
    print(state.label)
    exit(0)
}

if CommandLine.arguments.contains("--sample") {
    let sampler = SystemSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1)
    let bytes = try JSONSerialization.data(withJSONObject: sampler.sample(), options: [.prettyPrinted, .sortedKeys])
    print(String(data: bytes, encoding: .utf8)!)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
