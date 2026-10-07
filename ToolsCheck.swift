import Foundation

// Tools.swift 의 이름 변경·경로 해석 자체 검사. 실패하면 assert 로 멈춘다.
// swiftc -o /tmp/tools-check Tools.swift ToolsCheck.swift && /tmp/tools-check
@main
enum ToolsCheck {
    static func main() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("righto-check-\(UUID().uuidString)")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func file(_ name: String, _ body: String = "") -> URL {
            let url = dir.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: Data(body.utf8))
            return url
        }
        func names() -> Set<String> { Set(try! fm.contentsOfDirectory(atPath: dir.path)) }

        // 찾기/바꾸기 + 템플릿 + 번호 자릿수, 확장자 유지
        let many = (1...10).map { URL(fileURLWithPath: "/x/img\($0).jpg") }
        let planned = Rename.plan(many, find: "img", replace: "photo", template: "{n}_{name}")
        assert(planned[0].to.lastPathComponent == "01_photo1.jpg")
        assert(planned[9].to.lastPathComponent == "10_photo10.jpg")
        // 찾기는 필터: 찾을 문자열이 든 항목만 대상, 번호도 그 항목끼리
        let mixed = ["/x/IMG_1.jpg", "/x/a.txt", "/x/IMG_2.jpg"].map { URL(fileURLWithPath: $0) }
        let filtered = Rename.plan(mixed, find: "IMG_", replace: "X_", template: "{n}_{name}")
        assert(filtered.map(\.to.lastPathComponent) == ["1_X_1.jpg", "2_X_2.jpg"])

        // 같은 이름으로 모이면 중복, 빈 이름은 거부
        let a = file("a.txt", "A"), b = file("b.txt", "B"), c = file("c.txt")
        assert(Rename.plan([a, b], find: "", replace: "", template: "same").allSatisfy { $0.problem == "이름 중복" })
        assert(Rename.plan([a], find: "", replace: "", template: "").first?.problem == "쓸 수 없는 이름")
        // 선택하지 않은 기존 파일과 겹치면 거부
        assert(Rename.plan([a], find: "a", replace: "c", template: "{name}").first?.problem == "이미 있음")
        _ = c
        // 찾기에 안 걸린 기존 파일과 새 이름이 겹치면 거부
        let img = file("IMG_1.jpg"), x = file("X_1.jpg")
        assert(Rename.plan([img, x], find: "IMG_", replace: "X_", template: "{name}").map(\.problem) == ["이미 있음"])
        try! fm.removeItem(at: img); try! fm.removeItem(at: x)

        // 서로 이름 맞바꾸기
        let swap = [Rename.Item(from: a, to: b, problem: nil), Rename.Item(from: b, to: a, problem: nil)]
        assert(Rename.apply(swap).isEmpty)
        assert(try! String(contentsOf: a, encoding: .utf8) == "B")
        assert(try! String(contentsOf: b, encoding: .utf8) == "A")

        // 대소문자만 바꾸기
        let upper = Rename.plan([a], find: "a", replace: "A", template: "{name}")
        assert(upper.first?.problem == nil)
        assert(Rename.apply(upper).isEmpty)
        assert(names() == ["A.txt", "b.txt", "c.txt"])

        // 경로 해석
        let base = URL(fileURLWithPath: "/tmp/base")
        assert(resolvePath("  ../x \n", base: base).path == "/tmp/x")
        assert(resolvePath("'/a b/it'\\''s'", base: base).path == "/a b/it's")
        assert(resolvePath("/a\\ b", base: base).path == "/a b")
        assert(resolvePath("~/Desktop", base: base).path == NSHomeDirectory() + "/Desktop")
        print("ok")
    }
}
