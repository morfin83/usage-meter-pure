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
    let quota = MeterRow(L("Zbývá · krátkodobý limit"), remaining: true, tint: Palette.quota)
    let weekly = MeterRow(L("Zbývá · dlouhodobý limit"), remaining: true, tint: Palette.weekly)
    let cpu = MeterRow("CPU", tint: Palette.cpu)
    let ram = MeterRow("RAM", tint: Palette.ram)
    let gpu = MeterRow("GPU", tint: Palette.gpu)
    let network = MeterRow(L("Síť"), tint: Palette.network)
    let updated = NSTextField(labelWithString: L("Limity: načítání…"))
    let creditLabel = NSTextField(labelWithString: L("Tokeny: API neposkytuje"))
    var telemetryTimer: Timer?
    var usageTimer: Timer?
    var isFetching = false
    var pinnedEverywhere = true
    var lastUsage: Date?
    var lastFetchFailed = false
    var usageProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
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
        usageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
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
        aiBody = vertical([quota, weekly, creditLabel, updated], spacing: 12)
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
            let result = data
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
                self.applyUsage(data)
            }
        }
    }

    func applyUsage(_ data: [String: Any]) {
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
            creditLabel.stringValue = LF("Kredity: %@ · tokeny: API neposkytuje", balance)
        } else { creditLabel.stringValue = L("Kredity / tokeny: API neposkytuje zůstatek") }
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
