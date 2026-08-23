import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var statusBarController: MacosStatusBarController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 引擎默认 FlutterView 的 layer 背景是黑色（FlutterView.mm 里
    // `[self setBackgroundColor:[NSColor blackColor]]`）。滚动/切页时若有
    // 一帧合成不及时，Metal layer 露出的就是黑底 → 整窗黑屏闪烁。
    // 这里先按系统外观设一个与 App 主题一致的底色；Flutter 侧
    // （MacosWindowBackgroundService）再通过 channel 精确同步实际主题色。
    flutterViewController.backgroundColor = resolveInitialBackground()

    RegisterGeneratedPlugins(registry: flutterViewController)
    // 窗口背景色同步通道：Flutter 侧把主题背景色（ARGB int）推到这里，
    // 覆盖上面的初始底色，并跟随主题/系统亮暗实时更新。
    let windowChannel = FlutterMethodChannel(
      name: "com.feiniu.music/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowChannel.setMethodCallHandler { [weak flutterViewController] call, result in
      guard call.method == "setBackgroundColor",
            let argb = call.arguments as? Int else {
        result(FlutterMethodNotImplemented)
        return
      }
      let a = Double((argb >> 24) & 0xFF) / 255.0
      let r = Double((argb >> 16) & 0xFF) / 255.0
      let g = Double((argb >> 8) & 0xFF) / 255.0
      let b = Double(argb & 0xFF) / 255.0
      flutterViewController?.backgroundColor = NSColor(
        srgbRed: r, green: g, blue: b, alpha: a)
      result(nil)
    }

    statusBarController = MacosStatusBarController(
      binaryMessenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// 与 App 主题背景色一致（暗色 #080808 / 亮色 #F7F7F7，见
  /// app_visual_theme.dart），启动首帧前先用系统外观定一个接近的底色。
  private func resolveInitialBackground() -> NSColor {
    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    if isDark {
      return NSColor(srgbRed: 0x08 / 255.0, green: 0x08 / 255.0, blue: 0x08 / 255.0, alpha: 1)
    }
    return NSColor(srgbRed: 0xF7 / 255.0, green: 0xF7 / 255.0, blue: 0xF7 / 255.0, alpha: 1)
  }
}

private final class MacosStatusBarController: NSObject {
  private let statusItem: NSStatusItem
  private let methodChannel: FlutterMethodChannel
  private var lastTitle = "飞牛音乐"
  private var lastArtist = ""
  private var isPlaying = false

  init(binaryMessenger: FlutterBinaryMessenger) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    methodChannel = FlutterMethodChannel(
      name: "com.feiniu.music/statusbar",
      binaryMessenger: binaryMessenger)
    super.init()

    configureStatusItemButton()
    statusItem.button?.title = lastTitle
    statusItem.button?.toolTip = "飞牛音乐"
    statusItem.menu = buildMenu()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    DispatchQueue.main.async { [weak self] in
      self?.methodChannel.invokeMethod("ready", arguments: nil)
    }
  }

  private func configureStatusItemButton() {
    guard let button = statusItem.button,
          let image = NSImage(named: "StatusBarIcon") else {
      return
    }
    image.isTemplate = true
    image.size = NSSize(width: 18, height: 18)
    button.image = image
    button.imagePosition = .imageLeading
    button.imageScaling = .scaleProportionallyDown
    button.setAccessibilityLabel("飞牛音乐")
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let titleItem = NSMenuItem(title: lastTitle, action: nil, keyEquivalent: "")
    titleItem.isEnabled = false
    menu.addItem(titleItem)
    if !lastArtist.isEmpty {
      let artistItem = NSMenuItem(title: lastArtist, action: nil, keyEquivalent: "")
      artistItem.isEnabled = false
      menu.addItem(artistItem)
    }
    menu.addItem(NSMenuItem.separator())

    let playItem = NSMenuItem(
      title: isPlaying ? "暂停" : "播放",
      action: #selector(playPauseTapped(_:)),
      keyEquivalent: "")
    playItem.target = self
    menu.addItem(playItem)

    let nextItem = NSMenuItem(title: "下一首", action: #selector(nextTapped(_:)), keyEquivalent: "")
    nextItem.target = self
    menu.addItem(nextItem)

    let previousItem = NSMenuItem(title: "上一首", action: #selector(previousTapped(_:)), keyEquivalent: "")
    previousItem.target = self
    menu.addItem(previousItem)
    menu.addItem(NSMenuItem.separator())

    let quitItem = NSMenuItem(title: "退出 飞牛音乐", action: #selector(quitTapped(_:)), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)
    return menu
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "ping":
      result(nil)
    case "setState":
      if let args = call.arguments as? [String: Any] {
        lastTitle = (args["title"] as? String) ?? "飞牛音乐"
        lastArtist = (args["artist"] as? String) ?? ""
        isPlaying = (args["isPlaying"] as? Bool) ?? false
        let idle = (args["isIdle"] as? Bool) ?? false
        if idle || lastTitle.isEmpty {
          statusItem.button?.title = "飞牛音乐"
          statusItem.button?.toolTip = "飞牛音乐"
        } else {
          statusItem.button?.title = truncate(lastTitle, max: 28)
          let playbackState = isPlaying ? "正在播放" : "已暂停"
          let songDescription = lastArtist.isEmpty ? lastTitle : "\(lastTitle) — \(lastArtist)"
          statusItem.button?.toolTip = "\(playbackState)：\(songDescription)"
        }
        statusItem.menu = buildMenu()
      }
      result(nil)
    case "show":
      statusItem.isVisible = true
      result(nil)
    case "hide":
      statusItem.isVisible = false
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func truncate(_ value: String, max: Int) -> String {
    guard value.count > max else { return value }
    return String(value.prefix(max)) + "…"
  }

  @objc private func playPauseTapped(_ sender: Any) {
    methodChannel.invokeMethod("playPause", arguments: nil)
  }

  @objc private func nextTapped(_ sender: Any) {
    methodChannel.invokeMethod("next", arguments: nil)
  }

  @objc private func previousTapped(_ sender: Any) {
    methodChannel.invokeMethod("previous", arguments: nil)
  }

  @objc private func quitTapped(_ sender: Any) {
    NSApp.terminate(nil)
  }
}
