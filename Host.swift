import Cocoa

// Righto.app: 실행하면 설정 창(터미널·에디터 선택)을 띄운다.
// Finder 확장은 샌드박스라 이 앱에 righto:// URL 로 요청한다:
//   toggle-hidden (숨김 파일 전환), rename?dir=<폴더> (이름 일괄 변경), goto?base=<폴더> (폴더로 이동)
// build.sh 는 --register 로 실행해 등록만 하고 바로 끝낸다.

func run(_ path: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try? process.run()
    process.waitUntilExit()
}

func toggleHidden() {
    let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    // 손쉬운 사용 권한이 있으면 Finder 에 Cmd+Shift+. 를 보낸다 (재시작 없음).
    if AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary),
       let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 47, keyDown: down)!  // 47 = '.'
            event.flags = [.maskCommand, .maskShift]
            event.postToPid(finder.processIdentifier)
        }
        Thread.sleep(forTimeInterval: 0.3)
        return
    }
    // ponytail: 권한이 없으면 설정을 바꾸고 Finder 를 재시작한다 (화면이 깜박임). 권한 부여 후에는 위 경로 사용.
    let finder = UserDefaults(suiteName: "com.apple.finder")!
    finder.set(!finder.bool(forKey: "AppleShowAllFiles"), forKey: "AppleShowAllFiles")
    finder.synchronize()
    run("/usr/bin/killall", ["Finder"])
}

// DMG 로 설치하면 확장이 등록만 되고 꺼진 상태라 우클릭 메뉴에 나오지 않는다.
// 확장을 등록·활성화하고 Finder 를 재시작해 바로 메뉴에 반영한다 (build.sh 의 설치 단계와 같다).
func enableExtension() {
    guard let id = Bundle.main.bundleIdentifier,
          let ext = Bundle.main.builtInPlugInsURL?.appendingPathComponent("FinderMenu.appex") else { return }
    run("/usr/bin/pluginkit", ["-a", ext.path])
    run("/usr/bin/pluginkit", ["-e", "use", "-i", id + ".finder"])
    run("/usr/bin/killall", ["Finder"])
}

final class Delegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var launchedByURL = false
    private let terminalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let editorPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // URL 로 실행된 경우에는 설정 창을 띄우지 않고, 남은 창(이름 변경)이 없으면 끝낸다. URL 이벤트가 도착할 시간을 잠깐 준다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            guard launchedByURL else { return showWindow() }
            if !NSApp.windows.contains(where: \.isVisible) { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // 이미 실행 중인 상태에서 다시 열면(Dock, 더블클릭) 설정 창을 앞으로 가져온다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue.flatMap(URLComponents.init(string:)) else { return }
        if window == nil { launchedByURL = true }
        let query = url.queryItems ?? []
        switch url.host {
        case "toggle-hidden": toggleHidden()
        case "rename": RenameWindow.show(URL(fileURLWithPath: query.first { $0.name == "dir" }?.value ?? NSHomeDirectory()))
        case "goto": goTo(base: URL(fileURLWithPath: query.first { $0.name == "base" }?.value ?? NSHomeDirectory()))
        default: break
        }
    }

    // MARK: 설정 창

    // 팝업에서 고른 값은 pending 에만 두고, '적용'을 눌러야 저장한다. '적용'은 확장 활성화·Finder 재시작도 하므로 항상 켜 둔다.
    private var pending = (terminal: Config.terminal, editor: Config.editor)
    private let applyButton = NSButton(title: "적용", target: nil, action: nil)

    private func showWindow() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        pending = (Config.terminal, Config.editor)
        for (popup, tag) in [(terminalPopup, 0), (editorPopup, 1)] {
            popup.tag = tag
            popup.target = self
            popup.action = #selector(picked(_:))
            popup.controlSize = .large
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        refill()

        let close = NSButton(title: "닫기", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(apply)
        applyButton.keyEquivalent = "\r"
        for button in [close, applyButton] {
            button.controlSize = .large
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
        }
        let version = NSTextField(labelWithString: "버전 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        version.textColor = .secondaryLabelColor
        // 버전은 왼쪽 끝, 버튼은 오른쪽 끝에 둔다.
        let buttons = NSStackView()
        buttons.spacing = 8
        buttons.setViews([version], in: .leading)
        buttons.setViews([close, applyButton], in: .trailing)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "터미널"), terminalPopup],
            [NSTextField(labelWithString: "에디터"), editorPopup],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for row in 0..<grid.numberOfRows {  // 라벨도 컨트롤 크기에 맞춘다
            (grid.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField)?.font = .systemFont(ofSize: 14)
        }

        let content = NSStackView(views: [grid, buttons])
        content.orientation = .vertical
        content.alignment = .trailing
        content.spacing = 20
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Righto 설정"
        // NSStackView.edgeInsets 는 fittingSize 에 반영되지 않아서, 컨테이너에 제약으로 여백을 준다.
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        window.contentView = container
        window.setContentSize(container.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func refill() {
        fill(terminalPopup, Config.terminals, current: pending.terminal)
        fill(editorPopup, Config.editors, current: pending.editor)
    }

    private func fill(_ popup: NSPopUpButton, _ candidates: [URL], current: URL) {
        popup.removeAllItems()
        let apps = candidates.contains(current) ? candidates : [current] + candidates
        for app in apps {
            let item = NSMenuItem(title: Config.name(app), action: nil, keyEquivalent: "")
            item.representedObject = app
            item.image = Config.icon(app)
            popup.menu?.addItem(item)
        }
        popup.menu?.addItem(.separator())
        popup.menu?.addItem(NSMenuItem(title: "기타…", action: nil, keyEquivalent: ""))
        popup.selectItem(at: apps.firstIndex(of: current) ?? 0)
    }

    @objc private func picked(_ popup: NSPopUpButton) {
        var chosen = popup.selectedItem?.representedObject as? URL
        if chosen == nil {  // '기타…'
            let panel = NSOpenPanel()
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            chosen = panel.runModal() == .OK ? panel.url : nil
        }
        if let chosen {
            if popup.tag == 0 { pending.terminal = chosen } else { pending.editor = chosen }
        }
        refill()  // 취소했으면 이전 선택으로 복귀, '기타…'로 고른 앱은 목록에 추가된다
    }

    @objc private func apply() {
        Config.set(terminal: pending.terminal, editor: pending.editor)
        enableExtension()
    }

    @objc private func closeWindow() { window?.close() }
}

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--register") { exit(0) }
        let delegate = Delegate()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}
