import AppKit
import Darwin
import Foundation

// MARK: - 流量计数器（getifaddrs 读取网卡字节数）

private final class TrafficSampler {
    /// 每个网卡上一次采样的计数（处理 32 位计数器回绕）
    private var lastUp: [String: UInt64] = [:]
    private var lastDown: [String: UInt64] = [:]

    /// 本次进程运行以来的累计流量
    private(set) var totalUp: UInt64 = 0
    private(set) var totalDown: UInt64 = 0

    private func shouldCount(_ name: String) -> Bool {
        // 只统计物理网卡（en*：Wi-Fi、有线、USB 网卡）。
        // utun/ipsec/ppp 等隧道接口的字节已经封装在物理网卡里，bridge/vmenet 等虚拟接口
        // 同样与底层物理网卡重复，一起计入会把同一份流量算两遍。
        // 这同时排除了 lo*/awdl*/llw* 等虚拟接口。
        name.hasPrefix("en")
    }

    /// 读取当前所有网卡的累计字节数
    private func snapshot() -> (up: [String: UInt64], down: [String: UInt64]) {
        var up: [String: UInt64] = [:]
        var down: [String: UInt64] = [:]

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            return ([:], [:])
        }
        defer { freeifaddrs(ifaddrPtr) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = current {
            defer { current = ifa.pointee.ifa_next }

            guard let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = ifa.pointee.ifa_data else {
                continue
            }
            guard let ifname = String(validatingUTF8: ifa.pointee.ifa_name), shouldCount(ifname) else {
                continue
            }

            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            // 同一网卡可能有多条记录，取最大值防止重复累加
            let rx = UInt64(data.ifi_ibytes)
            let tx = UInt64(data.ifi_obytes)
            down[ifname] = max(down[ifname] ?? 0, rx)
            up[ifname] = max(up[ifname] ?? 0, tx)
        }
        return (up, down)
    }

    private func delta(name: String, old: UInt64?, new: UInt64) -> UInt64 {
        guard let old else { return 0 }
        if new >= old { return new - old }
        // 32 位计数器回绕
        return (UInt64(UInt32.max) - old) + new + 1
    }

    /// 采样一次，返回自上次采样以来所有网卡的上传/下载字节增量；首次调用返回 0。
    /// 注意：这里返回的是「字节数」而非速率，除以真实间隔由调用方负责。
    func sample() -> (up: UInt64, down: UInt64) {
        let (curUp, curDown) = snapshot()
        var dUp: UInt64 = 0
        var dDown: UInt64 = 0

        for (name, bytes) in curUp {
            let d = delta(name: name, old: lastUp[name], new: bytes)
            if lastUp[name] != nil { dUp += d }
        }
        for (name, bytes) in curDown {
            let d = delta(name: name, old: lastDown[name], new: bytes)
            if lastDown[name] != nil { dDown += d }
        }

        lastUp = curUp
        lastDown = curDown
        totalUp += dUp
        totalDown += dDown

        return (dUp, dDown)
    }
}

// MARK: - 速率格式化：B / K / M / G 自动进位

/// 速率单位，逐级 1024 进位
private let rateUnits = ["K", "M", "G", "T"]

/// 把 bytes/s 换算成 (数值, 单位下标)。
/// 先按 1 位小数四舍五入，再判断是否需要进位：否则 1023.96K 会被格式化成越界的
/// "1024.0K"（既不是合法进位，又比固定宽度多 1 个字符）。
/// 进位阈值取 1000 而不是 1024：显示值最多 4 位整数，保证数值恒为 5 字符宽度，
/// 状态栏不会因为跨过 1000 而变宽/裁字；实际单位换算仍按 1024。
private func scaledRate(_ bytesPerSecond: Double) -> (value: Double, unitIndex: Int) {
    var value = bytesPerSecond / 1024
    var unitIndex = 0
    while unitIndex < rateUnits.count - 1 {
        let rounded = (value * 10).rounded() / 10
        if rounded < 1000 { return (rounded, unitIndex) }
        value = rounded / 1024
        unitIndex += 1
    }
    return ((value * 10).rounded() / 10, unitIndex)
}

func formatRate(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "0B" }
    if bytesPerSecond < 1024 {
        return String(format: "%.0fB", bytesPerSecond)
    }
    let scaled = scaledRate(bytesPerSecond)
    return String(format: "%.1f%@", scaled.value, rateUnits[scaled.unitIndex])
}

/// 菜单栏显示用：数值右对齐到 5 字符宽度（最多 4 位整数 + 小数点 + 1 位小数，如 "999.9"），再加 1 字符单位
/// 例：  "  0.0K" " 12.3M" "999.9G"
func formatRateFixed(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "  0.0K" }
    let scaled = scaledRate(bytesPerSecond)
    return String(format: "%5.1f%@", scaled.value, rateUnits[scaled.unitIndex])
}

func formatTotal(_ bytes: UInt64) -> String {
    let b = Double(bytes)
    if b < 1024 { return String(format: "%.0f B", b) }
    // 先换算到 KB 再开始进位，否则数值还是字节却挂着 KB 标签，会导致整体大一级（1024 倍）
    var value = b / 1024
    var unitIndex = 0
    let units = ["KB", "MB", "GB", "TB"]
    while value >= 1024, unitIndex < units.count - 1 {
        value /= 1024
        unitIndex += 1
    }
    return String(format: "%.1f %@", value, units[unitIndex])
}

// MARK: - 菜单栏应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let sampler = TrafficSampler()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var activity: NSObjectProtocol?

    private var currentUp: Double = 0
    private var currentDown: Double = 0
    /// 上一次采样的单调时间戳（秒，含系统睡眠），用于把字节增量归一化成真实速率
    private var lastSampleTime: Double?

    private let totalUpItem = NSMenuItem(title: "本次累计上传：—", action: nil, keyEquivalent: "")
    private let totalDownItem = NSMenuItem(title: "本次累计下载：—", action: nil, keyEquivalent: "")
    private let rateItem = NSMenuItem(title: "当前速率：—", action: nil, keyEquivalent: "")

    private static let fontSize: CGFloat = 9
    /// 文字墨迹中心相对行块几何中心的上偏量（与字体/行高绑定，改动字号行高需重新校准）
    private static let inkbias: CGFloat = 1.25
    /// 是否已按最大宽度锁定状态栏长度
    private var lengthLocked = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 先用可变长度创建，首次渲染后立刻锁定为固定长度，彻底消除抖动
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // 上下两行排版：上传在上、下载在下；等宽数字 + 粗体
            button.font = NSFont.monospacedDigitSystemFont(ofSize: Self.fontSize, weight: .bold)
            button.cell?.wraps = true
            button.cell?.lineBreakMode = .byClipping
        }

        let menu = NSMenu()
        // 菜单里的速率/累计是只读信息项（action 为 nil），默认的自动启用逻辑会把它们置灰，
        // 看起来像不可用；关闭自动校验让它们保持正常字色
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(rateItem)
        menu.addItem(.separator())
        menu.addItem(totalUpItem)
        menu.addItem(totalDownItem)
        menu.addItem(.separator())
        // 不带 keyEquivalent：accessory 应用不在 mainMenu 里，⌘Q 实际不会触发，
        // 显示出来只会是假承诺；退出统一走点击菜单
        let quit = NSMenuItem(title: "退出 SpeedBar", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        // 只抑制 App Nap 对 1 秒轮询的节流，不阻止整机空闲休眠。
        // 注意：.userInitiated 内含 NSActivityIdleSystemSleepDisabled，会让 Mac 无法空闲休眠；
        // .latencyCritical 是音视频录制级的最高优先级，这里不需要。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "菜单栏网速轮询"
        )

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.1
        // 加入 .common 模式：菜单打开（event tracking）期间也继续采样，
        // 否则菜单关闭瞬间会把整段打开期间的流量当成 1 秒上报
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // 显示器排列/分辨率变化后重新按当前字体锁定状态栏宽度
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        tick()
    }

    /// 单调递增且包含系统睡眠的时间（秒），不受系统时钟调整影响
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    private static func continuousTime() -> Double {
        Double(mach_continuous_time()) * timebase / 1_000_000_000
    }

    private func tick() {
        let now = Self.continuousTime()
        let bytes = sampler.sample()

        let elapsed = lastSampleTime.map { now - $0 } ?? 0
        lastSampleTime = now

        if elapsed >= 0.05, elapsed <= 60 {
            // 按真实间隔归一化：定时器被延迟、菜单打开、唤醒后都不会再出现 N 倍假尖峰
            currentUp = Double(bytes.up) / elapsed
            currentDown = Double(bytes.down) / elapsed
        }
        // 首次采样（elapsed == 0）或休眠/长时间挂起（> 60s）时不更新显示值，
        // 避免把整段间隔积攒的字节当成 1 秒的瞬时速率

        render()
    }

    private func render() {
        guard let button = statusItem.button else { return }
        // 上下两行：↑上传 在上、↓下载 在下；数值固定 5 字符 + 单位 1 字符，字符数恒定
        let title = "↑\(formatRateFixed(currentUp))\n↓\(formatRateFixed(currentDown))"
        let font = button.font ?? NSFont.monospacedDigitSystemFont(ofSize: Self.fontSize, weight: .bold)
        let style = NSMutableParagraphStyle()
        // 左对齐：数字虽是等宽，但单位字母 K/M/G/T 宽度不同，居中会导致两行箭头左右错位
        style.alignment = .left
        style.minimumLineHeight = 9.5
        style.maximumLineHeight = 9.5
        var titleAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: style,
        ]
        // 垂直居中：新版菜单栏视觉高度(约30pt)大于按钮高度(22pt)，文字块按菜单栏高度重新居中
        // inkBias: 文字墨迹中心比行块几何中心高约1.25pt(9pt粗体的字形上沿留白)，需要扣除
        let attributed = NSAttributedString(string: title, attributes: titleAttrs)
        let titleHeight = ceil(attributed.size().height)
        let barHeight = max(button.window?.frame.height ?? 0, button.frame.height)
        let verticalShift = max(0, (barHeight - titleHeight) / 2 - Self.inkbias)
        if verticalShift > 0.1 {
            titleAttrs[.baselineOffset] = -verticalShift
        }
        button.attributedTitle = NSAttributedString(string: title, attributes: titleAttrs)

        // 首次渲染后按最宽可能值锁定状态栏长度，之后数值变化也不再改变宽度；
        // 菜单栏文字大小/显示器变化时重新计算
        if !lengthLocked {
            lockLength(font: font)
            lengthLocked = true
        }
    }

    /// 按「↑ / ↓ × K/M/G/T」各组合里最宽的字符串锁定状态栏长度。
    /// 显示值最大为 999.9（4 位整数 + 1 位小数），K/M/G/T 字母宽度不同，需要逐项量取最大值。
    private func lockLength(font: NSFont) {
        var width: CGFloat = 0
        for arrow in ["↑", "↓"] {
            for unit in rateUnits {
                let candidate = "\(arrow)999.9\(unit)"
                let candidateWidth = NSAttributedString(
                    string: candidate,
                    attributes: [.font: font]
                ).size().width
                width = max(width, candidateWidth)
            }
        }
        statusItem.length = ceil(width) + 4
    }

    /// 显示器排列/分辨率/菜单栏文字大小变化后，重新按最新字体锁定宽度
    @objc private func screenParametersChanged() {
        guard let button = statusItem.button else { return }
        let font = button.font ?? NSFont.monospacedDigitSystemFont(ofSize: Self.fontSize, weight: .bold)
        lockLength(font: font)
        render()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rateItem.title = String(
            format: "当前速率：↑ %@ / ↓ %@",
            formatRate(currentUp),
            formatRate(currentDown)
        )
        totalUpItem.title = "本次累计上传：" + formatTotal(sampler.totalUp)
        totalDownItem.title = "本次累计下载：" + formatTotal(sampler.totalDown)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
