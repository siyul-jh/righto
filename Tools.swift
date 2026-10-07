import Cocoa

// Finder 확장이 righto:// URL 로 요청하는 도구들. 샌드박스 밖(Righto.app)에서 창을 띄우고 파일을 다룬다.

// MARK: 일괄 이름 변경

enum Rename {
    struct Item {
        let from: URL
        let to: URL
        let problem: String?
    }

    // 확장자는 유지하고 이름 부분에만 찾기/바꾸기를 한 뒤 템플릿을 적용한다. {name} = 원래 이름, {n} = 번호(1부터, 개수 자릿수만큼 0 채움).
    // 찾기가 있으면 이름에 그 문자열이 든 항목만 대상으로 삼는다(번호도 그 항목끼리). 대상이 아닌 항목은 결과에 넣지 않는다.
    static func plan(_ all: [URL], find: String, replace: String, template: String) -> [Item] {
        func stem(_ url: URL) -> String {
            url.hasDirectoryPath || url.pathExtension.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        }
        let urls = all.filter { find.isEmpty || stem($0).contains(find) }
        let digits = String(urls.count).count
        let names = urls.enumerated().map { i, url -> String in
            let ext = url.hasDirectoryPath ? "" : url.pathExtension
            var stem = stem(url)
            if !find.isEmpty { stem = stem.replacingOccurrences(of: find, with: replace) }
            stem = template.replacingOccurrences(of: "{name}", with: stem)
                .replacingOccurrences(of: "{n}", with: String(format: "%0\(digits)d", i + 1))
            return ext.isEmpty || stem.isEmpty ? stem : "\(stem).\(ext)"  // 이름이 비면 '.txt' 같은 숨김 파일이 되지 않게 빈 값으로 둔다
        }
        let targets = zip(urls, names).map { $0.deletingLastPathComponent().appendingPathComponent($1) }
        // ponytail: 대소문자 구분 없는 APFS 기준으로 비교한다. 대소문자 구분 볼륨에서는 중복을 과하게 잡을 수 있다.
        let keys = targets.map { $0.path.lowercased() }
        let counts = Dictionary(keys.map { ($0, 1) }, uniquingKeysWith: +)
        let sources = Set(urls.map { $0.path.lowercased() })
        return urls.indices.map { i in
            let problem: String? =
                names[i].isEmpty || names[i].contains("/") ? "쓸 수 없는 이름" :
                counts[keys[i]]! > 1 ? "이름 중복" :
                !sources.contains(keys[i]) && FileManager.default.fileExists(atPath: targets[i].path) ? "이미 있음" : nil
            return Item(from: urls[i], to: targets[i], problem: problem)
        }
    }

    // 서로 이름을 맞바꾸거나 대소문자만 바꾸는 경우를 위해 임시 이름을 거쳐 두 단계로 옮긴다. 실패한 항목은 원래 이름으로 되돌린다.
    static func apply(_ items: [Item]) -> [String] {
        let fm = FileManager.default
        var errors: [String] = []
        var moved: [(Item, URL)] = []
        for item in items where item.from.path != item.to.path {
            let tmp = item.from.deletingLastPathComponent().appendingPathComponent(".righto-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: item.from, to: tmp)
                moved.append((item, tmp))
            } catch {
                errors.append("\(item.from.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for (item, tmp) in moved {
            do {
                try fm.moveItem(at: tmp, to: item.to)
            } catch {
                let restored = (try? fm.moveItem(at: tmp, to: item.from)) != nil
                errors.append("\(item.from.lastPathComponent): \(error.localizedDescription)"
                    + (restored ? "" : " (임시 이름 \(tmp.lastPathComponent)으로 남음)"))
            }
        }
        return errors
    }
}

// URL 로 백그라운드에서 실행된 앱은 NSApp.activate 가 무시된다(macOS 14+). LaunchServices 로 자신을 다시 열어 앞으로 가져온다.
// 다시 열기 이벤트로 설정 창이 뜨지 않도록 한 번 무시하게 표시한다.
var ignoreNextReopen = false

func bringToFront() {
    ignoreNextReopen = true
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
}

// 앱 번들의 메뉴 아이콘(rename.png, goto.png)을 창 머리에 쓴다.
private func bundleIcon(_ name: String) -> NSImage? {
    Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
}

private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingMiddle
    return field
}

final class RenameWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static var live: [RenameWindow] = []

    private let dir: URL
    private let urls: [URL]
    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let templateField = NSTextField(string: "{name}")
    private let table = NSTableView()
    private let summary = label("")
    private let applyButton = NSButton(title: "이름 바꾸기", target: nil, action: nil)
    private let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    private var items: [Rename.Item] = []

    // 폴더 안의 항목(숨김 제외)이 후보이고, 찾기에 맞는 항목만 바꾼다.
    static func show(_ dir: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        guard !urls.isEmpty else { return }
        live.append(RenameWindow(dir, urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }))
    }

    private init(_ dir: URL, _ urls: [URL]) {
        self.dir = dir
        self.urls = urls
        super.init()

        // 머리: 아이콘 + 제목 + 대상 폴더
        let icon = NSImageView(image: bundleIcon("rename") ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let folder = (dir.path as NSString).abbreviatingWithTildeInPath
        let subtitle = label("\(urls.count)개 항목 · \(folder)", color: .secondaryLabelColor)
        subtitle.setContentCompressionResistancePriority(.init(1), for: .horizontal)  // 긴 경로가 창 폭을 정하지 않고 가운데가 줄어들게
        let titles = NSStackView(views: [label("이름 일괄 변경", size: 17, weight: .semibold), subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let header = NSStackView(views: [icon, titles])
        header.spacing = 12

        // 입력
        findField.placeholderString = "찾을 문자열"
        replaceField.placeholderString = "바꿀 문자열 (비우면 지움)"
        templateField.placeholderString = "{name}"
        for field in [findField, replaceField, templateField] {
            field.delegate = self
            field.controlSize = .large
            field.font = .systemFont(ofSize: 13)
        }
        let tokens = NSStackView(views: [("{name}", "원래 이름 넣기"), ("{n}", "번호 넣기")].map { title, tip in
            let button = NSButton(title: title, target: self, action: #selector(insertToken(_:)))
            button.bezelStyle = .push
            button.controlSize = .small
            button.toolTip = tip
            return button
        })
        tokens.spacing = 4
        let templateRow = NSStackView(views: [templateField, tokens])
        templateRow.spacing = 8
        let grid = NSGridView(views: [
            [label("찾기"), findField],
            [label("바꾸기"), replaceField],
            [label("새 이름"), templateRow],
            [NSGridCell.emptyContentView, label("{name} 원래 이름 · {n} 번호(1부터). 확장자는 그대로 둔다.", size: 11, color: .secondaryLabelColor)],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        // 미리보기 표
        for (id, title, width) in [("from", "원래 이름", 200.0), ("to", "새 이름", 200.0), ("state", "상태", 90.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true

        // 아래: 요약 + 버튼
        let close = NSButton(title: "닫기", target: window, action: #selector(NSWindow.performClose(_:)))
        close.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(apply)
        applyButton.keyEquivalent = "\r"
        for button in [close, applyButton] {
            button.controlSize = .large
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [summary, spacer, close, applyButton])
        footer.spacing = 8

        let content = NSStackView(views: [header, grid, scroll, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.setCustomSpacing(22, after: header)
        for view in [scroll, footer] { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 36),  // 투명 제목 막대 높이만큼
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
        ])

        window.title = "이름 일괄 변경"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.delegate = self
        refresh()
        window.setContentSize(container.fittingSize)
        window.contentMinSize = container.fittingSize
        window.center()
        window.initialFirstResponder = findField
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        bringToFront()
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func windowWillClose(_ notification: Notification) { Self.live.removeAll { $0 === self } }

    @objc private func insertToken(_ sender: NSButton) {
        window.makeFirstResponder(templateField)
        (templateField.currentEditor() as? NSTextView)?.insertText(sender.title, replacementRange: templateField.currentEditor()!.selectedRange)
        refresh()
    }

    private func refresh() {
        items = Rename.plan(urls, find: findField.stringValue, replace: replaceField.stringValue, template: templateField.stringValue)
        table.reloadData()
        let changed = items.filter { $0.from.path != $0.to.path }.count
        let problems = items.filter { $0.problem != nil }.count
        summary.stringValue = problems > 0 ? "충돌 \(problems)개 — 이름을 고쳐야 바꿀 수 있다" : "\(changed)개 이름이 바뀐다"
        summary.textColor = problems > 0 ? .systemRed : .secondaryLabelColor
        applyButton.isEnabled = problems == 0 && changed > 0
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let changed = item.from.path != item.to.path
        // 빈 이름이면 to 가 부모 폴더를 가리키므로 이름을 보여 주지 않는다.
        let sameDir = item.to.deletingLastPathComponent().path == item.from.deletingLastPathComponent().path
        switch tableColumn?.identifier.rawValue {
        case "from":
            return label(item.from.lastPathComponent, color: changed ? .secondaryLabelColor : .labelColor)
        case "to":
            return label(sameDir ? item.to.lastPathComponent : "", weight: changed ? .medium : .regular,
                         color: item.problem != nil ? .systemRed : changed ? .labelColor : .tertiaryLabelColor)
        default:
            return label(item.problem.map { "⚠︎ \($0)" } ?? (changed ? "변경" : "그대로"),
                         color: item.problem != nil ? .systemRed : changed ? .systemGreen : .tertiaryLabelColor)
        }
    }

    @objc private func apply() {
        let errors = Rename.apply(items)
        if !errors.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "일부 항목의 이름을 바꾸지 못했다"
            alert.informativeText = errors.joined(separator: "\n")
            alert.runModal()
        }
        window.close()
    }
}

// MARK: 폴더로 이동

// 따옴표로 감싼 셸 경로, 백슬래시 이스케이프, ~, base 기준 상대 경로를 받는다.
func resolvePath(_ input: String, base: URL) -> URL {
    var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.count > 1, path.hasPrefix("'"), path.hasSuffix("'") {
        path = String(path.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
    } else {
        path = path.replacingOccurrences(of: "\\ ", with: " ")
    }
    let dir = URL(fileURLWithPath: base.path, isDirectory: true)  // 디렉터리로 표시하지 않으면 base 자체를 파일로 보고 한 단계 위를 기준으로 삼는다
    return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: dir).standardizedFileURL
}


// 입력하는 동안 경로가 무엇을 가리키는지 보여 주고, 없는 경로면 '이동'을 끈다.
private final class PathPreview: NSObject, NSTextFieldDelegate {
    let field = NSTextField(frame: NSRect(x: 0, y: 24, width: 420, height: 24))
    let status = label("", size: 11)
    let base: URL
    weak var goButton: NSButton?

    init(base: URL) {
        self.base = base
        super.init()
        field.placeholderString = "~/Documents, ../폴더, '/셸 경로'"
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        status.frame = NSRect(x: 2, y: 0, width: 418, height: 16)
    }

    // 존재하면 폴더 여부를 돌려준다.
    func target() -> (url: URL, isDir: Bool?) {
        let url = resolvePath(field.stringValue, base: base)
        var isDir: ObjCBool = false
        return (url, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) ? isDir.boolValue : nil)
    }

    func controlTextDidChange(_ obj: Notification) { update() }

    func update() {
        let (url, isDir) = target()
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        switch isDir {
        case true?: status.stringValue = "폴더 · \(path)"
        case false?: status.stringValue = "파일 · \(path) (선택해서 보여 준다)"
        case nil: status.stringValue = "찾을 수 없음 · \(path)"
        }
        status.textColor = isDir == nil ? .systemRed : .secondaryLabelColor
        goButton?.isEnabled = isDir != nil
    }
}

// Finder 의 '폴더로 이동(Cmd+Shift+G)'과 달리 클립보드의 경로를 미리 채우고, 파일 경로면 그 파일을 선택해 보여 준다.
// 입력 창이 마지막 창이라 닫히는 순간 앱이 끝나 버리므로, 이동을 마칠 때까지 종료를 미룬다.
var keepAlive = false

func goTo(base: URL) {
    keepAlive = true
    defer {
        keepAlive = false
        if !NSApp.windows.contains(where: \.isVisible) { NSApp.terminate(nil) }
    }
    let preview = PathPreview(base: base)
    let clip = NSPasteboard.general.string(forType: .string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    preview.field.stringValue = clip.flatMap { !$0.contains("\n") && FileManager.default.fileExists(atPath: resolvePath($0, base: base).path) ? $0 : nil }
        ?? (base.path as NSString).abbreviatingWithTildeInPath
    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 48))
    accessory.addSubview(preview.field)
    accessory.addSubview(preview.status)

    let alert = NSAlert()
    alert.icon = bundleIcon("goto")
    alert.messageText = "폴더로 이동"
    alert.informativeText = "~, 셸 경로, 현재 폴더 기준 상대 경로를 쓸 수 있다."
    preview.goButton = alert.addButton(withTitle: "이동")
    alert.addButton(withTitle: "취소")
    alert.accessoryView = accessory
    alert.window.initialFirstResponder = preview.field
    preview.update()
    bringToFront()
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let (url, isDir) = preview.target()
    guard let isDir else { return }  // 대화상자를 닫는 사이 지워진 경우
    if moveFrontWindow(from: base, to: isDir ? url : url.deletingLastPathComponent(), select: isDir ? nil : url) { return }
    if isDir { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

// 메뉴를 연 Finder 창(맨 앞 창이 base 를 보고 있을 때)을 새 창 없이 이동한다.
// 자동화 권한이 없거나 바탕화면·다른 창에서 열었으면 false 를 돌려주고, 호출한 쪽이 새 창으로 연다.
private func moveFrontWindow(from base: URL, to dir: URL, select file: URL?) -> Bool {
    func alias(_ url: URL) -> String {
        "(POSIX file \"" + url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\" as alias)"
    }
    let source = """
        tell application "Finder"
            if (count of Finder windows) is 0 then return false
            if POSIX path of (target of Finder window 1 as alias) is not POSIX path of \(alias(base)) then return false
            set target of Finder window 1 to \(alias(dir))
            \(file.map { "select \(alias($0))" } ?? "")
            activate
            return true
        end tell
        """
    var error: NSDictionary?
    return NSAppleScript(source: source)?.executeAndReturnError(&error).booleanValue ?? false
}
