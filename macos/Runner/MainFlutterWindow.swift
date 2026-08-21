import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var statusBarController: MacosStatusBarController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    // 窗口能显示就说明这里一定执行过；直接使用已创建的 Flutter engine
    // 注册状态栏通道，避免 AppDelegate 生命周期与 engine 初始化的竞态。
    statusBarController = MacosStatusBarController(
      binaryMessenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

private final class MacosStatusBarController: NSObject {
  private let statusItem: NSStatusItem
  private let methodChannel: FlutterMethodChannel
  private var lastTitle = "FeiNiu Music"
  private var lastArtist = ""
  private var isPlaying = false

  init(binaryMessenger: FlutterBinaryMessenger) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    methodChannel = FlutterMethodChannel(
      name: "com.feiniu.music/statusbar",
      binaryMessenger: binaryMessenger)
    super.init()

    statusItem.button?.title = lastTitle
    statusItem.button?.toolTip = "FeiNiu Music"
    statusItem.menu = buildMenu()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    DispatchQueue.main.async { [weak self] in
      self?.methodChannel.invokeMethod("ready", arguments: nil)
    }
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

    let quitItem = NSMenuItem(title: "退出 FeiNiu Music", action: #selector(quitTapped(_:)), keyEquivalent: "q")
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
        lastTitle = (args["title"] as? String) ?? "FeiNiu Music"
        lastArtist = (args["artist"] as? String) ?? ""
        isPlaying = (args["isPlaying"] as? Bool) ?? false
        let idle = (args["isIdle"] as? Bool) ?? false
        if idle || lastTitle.isEmpty {
          statusItem.button?.title = "FeiNiu Music"
          statusItem.button?.toolTip = "FeiNiu Music"
        } else {
          statusItem.button?.title = (isPlaying ? "▶ " : "⏸ ") + truncate(lastTitle, max: 28)
          statusItem.button?.toolTip = lastArtist.isEmpty ? lastTitle : "\(lastTitle) — \(lastArtist)"
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
