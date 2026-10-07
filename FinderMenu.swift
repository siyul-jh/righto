import Cocoa
import FinderSync

final class FinderMenu: FIFinderSync {
    private static let CUT_KEY = "cutPaths"
    private static let RELEASES = "https://github.com/siyul-jh/righto/releases/latest"
    private static let LATEST_API = URL(string: "https://api.github.com/repos/siyul-jh/righto/releases/latest")!
    private static let NEW_FILES: [(label: String, ext: String, body: String)] = [
        ("텍스트 (.txt)", "txt", ""), ("마크다운 (.md)", "md", ""), ("JSON (.json)", "json", "{}\n"),
        ("HTML (.html)", "html", "<!doctype html>\n"), ("Python (.py)", "py", ""), ("셸 스크립트 (.sh)", "sh", "#!/bin/bash\n"),
    ]

    override init() {
        super.init()
        let home = NSHomeDirectoryForUser(NSUserName())!
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: home + "/Library/Mobile Documents/com~apple~CloudDocs"),
            URL(fileURLWithPath: home + "/Library/CloudStorage"),
        ]
    }

    override var toolbarItemName: String { "Righto" }
    override var toolbarItemToolTip: String { "터미널 · 에디터 · 경로 복사 · 새 파일 · 잘라내기/붙여넣기" }
    override var toolbarItemImage: NSImage {
        Bundle.main.url(forResource: "toolbar", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "contextualmenu.and.cursorarrow", accessibilityDescription: nil)!
    }

    // MARK: 메뉴

    override func menu(for kind: FIMenuKind) -> NSMenu? {
        guard kind == .contextualMenuForContainer || kind == .contextualMenuForItems || kind == .toolbarItemMenu else { return nil }
        let menu = NSMenu()
        // 설정 창에서 고른 앱의 아이콘을 그대로 보여 준다.
        for (title, app, action) in [
            ("여기서 터미널 열기", Config.terminal, #selector(openTerminal)),
            ("에디터로 열기", Config.editor, #selector(openEditor)),
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.image = Config.icon(app)
        }

        let copy = NSMenu()
        for (i, title) in ["전체 경로", "이름만", "상대 경로"].enumerated() {
            add(copy, title, nil, #selector(copyPath(_:)), tag: i)
        }
        add(menu, "경로 복사", "copy", nil, sub: copy)

        let new = NSMenu()
        for (i, f) in Self.NEW_FILES.enumerated() { add(new, f.label, nil, #selector(newFile(_:)), tag: i) }
        add(menu, "새 파일", "new", nil, sub: new)

        add(menu, "잘라내기", "cut", #selector(cut))
        if !(UserDefaults.standard.stringArray(forKey: Self.CUT_KEY) ?? []).isEmpty {
            add(menu, "여기에 붙여넣기 (이동)", "paste", #selector(paste))
        }
        // 현재 상태에 따라 라벨을 바꾼다. Finder 는 확장 메뉴의 체크 표시(state)를 무시한다.
        // Finder 설정은 ext.entitlements 의 shared-preference 예외로 읽는다(Cmd+Shift+. 로 바꾼 상태도 반영).
        let showsHidden = UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "AppleShowAllFiles") ?? false
        add(menu, showsHidden ? "숨김 파일 가리기" : "숨김 파일 보기", "hidden", #selector(toggleHidden))
        add(menu, "이름 일괄 변경…", "rename", #selector(rename))
        add(menu, "폴더로 이동…", "goto", #selector(goTo))

        checkUpdate()
        if let latest = UserDefaults.standard.string(forKey: "latestVersion"), latest.compare(version, options: .numeric) == .orderedDescending {
            menu.addItem(.separator())
            add(menu, "새 버전 받기 (\(latest))", "update", #selector(openReleases))
        }
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ icon: String?, _ action: Selector?, tag: Int = 0, sub: NSMenu? = nil) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.tag = tag
        item.submenu = sub
        if let icon, let url = Bundle.main.url(forResource: icon, withExtension: "png"), let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 16, height: 16)
            item.image = image
        }
    }

    // MARK: 헬퍼

    private var base: URL? { FIFinderSyncController.default().targetedURL() }

    private var selection: [URL] {
        if let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty { return items }
        return base.map { [$0] } ?? []
    }

    private func folder(of url: URL) -> URL {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url : url.deletingLastPathComponent()
    }

    private func uniqueURL(_ dir: URL, _ name: String, _ ext: String) -> URL {
        var url = dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = dir.appendingPathComponent(ext.isEmpty ? "\(name) \(n)" : "\(name) \(n).\(ext)")
        }
        return url
    }

    // MARK: 동작

    @objc private func openTerminal() {
        for dir in Set(selection.map(folder(of:))) {
            NSWorkspace.shared.open([dir], withApplicationAt: Config.terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func openEditor() {
        NSWorkspace.shared.open(selection, withApplicationAt: Config.editor, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        let root = base?.path ?? ""
        let text = selection.map { url -> String in
            switch sender.tag {
            case 1: return url.lastPathComponent
            case 2: return url.path.hasPrefix(root + "/") ? String(url.path.dropFirst(root.count + 1)) : url.path
            default: return url.path
            }
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func newFile(_ sender: NSMenuItem) {
        let f = Self.NEW_FILES[sender.tag]
        var created: [URL] = []
        for dir in Set(selection.map(folder(of:))) {
            let url = uniqueURL(dir, "새 파일", f.ext)
            if FileManager.default.createFile(atPath: url.path, contents: Data(f.body.utf8)) { created.append(url) }
        }
        NSWorkspace.shared.activateFileViewerSelecting(created)
    }

    @objc private func cut() {
        UserDefaults.standard.set(selection.map(\.path), forKey: Self.CUT_KEY)
    }

    @objc private func paste() {
        guard let dir = selection.first.map(folder(of:)) else { return }
        var moved: [URL] = []
        for path in UserDefaults.standard.stringArray(forKey: Self.CUT_KEY) ?? [] {
            let src = URL(fileURLWithPath: path)
            let dst = src.deletingLastPathComponent() == dir ? src : uniqueURL(dir, src.deletingPathExtension().lastPathComponent, src.pathExtension)
            if dst != src, (try? FileManager.default.moveItem(at: src, to: dst)) != nil { moved.append(dst) }
        }
        UserDefaults.standard.removeObject(forKey: Self.CUT_KEY)
        NSWorkspace.shared.activateFileViewerSelecting(moved)
    }

    // 샌드박스 확장은 Finder 설정을 바꾸거나 창을 띄울 수 없어서 Righto.app 에 URL 로 요청한다.
    private func request(_ command: String, _ query: [URLQueryItem] = []) {
        var url = URLComponents(string: "righto://" + command)!
        if !query.isEmpty { url.queryItems = query }
        NSWorkspace.shared.open(url.url!)
    }

    @objc private func toggleHidden() { request("toggle-hidden") }

    @objc private func rename() { request("rename", base.map { [URLQueryItem(name: "dir", value: $0.path)] } ?? []) }

    @objc private func goTo() { request("goto", base.map { [URLQueryItem(name: "base", value: $0.path)] } ?? []) }

    // MARK: 업데이트 확인

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    // 메뉴를 열 때 하루에 한 번만 GitHub 최신 릴리스 태그를 받아 두고, 다음 메뉴부터 새 버전 항목을 보여 준다.
    private func checkUpdate() {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        guard now - defaults.double(forKey: "updateCheckedAt") > 86_400 else { return }
        defaults.set(now, forKey: "updateCheckedAt")
        URLSession.shared.dataTask(with: Self.LATEST_API) { data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            defaults.set(String(tag.trimmingPrefix("v")), forKey: "latestVersion")
        }.resume()
    }

    @objc private func openReleases() { NSWorkspace.shared.open(URL(string: Self.RELEASES)!) }
}
