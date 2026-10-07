import Cocoa

// 설정 창(Host)과 Finder 확장이 함께 쓰는 앱 선택 설정.
// 저장 위치: ~/Library/Application Support/Righto/config.json
enum Config {
    private struct Saved: Codable {
        var terminal: String?
        var editor: String?
    }

    // 폴더를 NSWorkspace 로 넘겨 여는 방식이 동작하는 터미널만 목록에 둔다. 그 밖의 앱은 '기타…'로 직접 고른다.
    static let TERMINAL_IDS = [
        "com.cmuxterm.app", "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.apple.Terminal",
    ]
    // 알려진 에디터 중 설치된 것만 노출한다. macOS 의 '텍스트를 열 수 있는 앱' 목록에는 브라우저·메모 앱까지 섞여서 쓰지 않는다.
    static let EDITOR_IDS = [
        "com.google.antigravity-ide", "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.zed.Zed",
        "com.sublimetext.4", "com.barebones.bbedit", "com.panic.Nova", "com.coteditor.CotEditor",
        "com.apple.dt.Xcode", "com.apple.TextEdit",
    ]

    private static var file: URL {
        URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName())! + "/Library/Application Support/Righto/config.json")
    }

    private static var saved: Saved {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    static func name(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    // 앱 아이콘은 16~2048px 표현을 모두 들고 있어(약 74MB) 메뉴를 XPC 로 Finder 에 넘길 때 지연이 생긴다.
    // 32px(16pt @2x) 비트맵 하나로 다시 그려 넘긴다.
    static func icon(_ app: URL) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: app.path)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.addRepresentation(rep)
        return image
    }

    private static func installed(_ ids: [String]) -> [URL] {
        ids.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    static var terminals: [URL] { installed(TERMINAL_IDS) }

    static var editors: [URL] { installed(EDITOR_IDS) }

    // 저장된 앱이 없거나 지워졌으면 설치된 후보 중 첫 번째, 그것도 없으면 macOS 기본 앱.
    static var terminal: URL {
        pick(saved.terminal, terminals) ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    }

    static var editor: URL {
        pick(saved.editor, editors) ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    }

    private static func pick(_ path: String?, _ candidates: @autoclosure () -> [URL]) -> URL? {
        if let path, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        return candidates().first
    }

    static func set(terminal: URL? = nil, editor: URL? = nil) {
        var current = saved
        if let terminal { current.terminal = terminal.path }
        if let editor { current.editor = editor.path }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(current).write(to: file)
    }
}
