import XCTest
@testable import MyClaw

/// 测试 SKILL.md 解析逻辑
final class SkillImportTests: XCTestCase {

    // MARK: - SKILL.md 解析

    /// 解析带 YAML frontmatter 的 SKILL.md
    private func parseSkillMD(_ content: String, folderName: String = "test") -> [String: Any]? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var frontmatter: [String: String] = [:]
        var body = trimmed

        if trimmed.hasPrefix("---") {
            let parts = trimmed.dropFirst(3).components(separatedBy: "\n---")
            if parts.count >= 2 {
                let yamlBlock = parts[0]
                body = parts.dropFirst().joined(separator: "\n---").trimmingCharacters(in: .whitespacesAndNewlines)
                for line in yamlBlock.components(separatedBy: .newlines) {
                    let kv = line.split(separator: ":", maxSplits: 1)
                    if kv.count == 2 {
                        let key = kv[0].trimmingCharacters(in: .whitespaces)
                        let val = kv[1].trimmingCharacters(in: .whitespaces)
                        frontmatter[key] = val
                    }
                }
            }
        }

        guard !body.isEmpty else { return nil }
        let name = frontmatter["name"] ?? folderName.replacingOccurrences(of: ".md", with: "")

        var skill: [String: Any] = [
            "name": name,
            "description": frontmatter["description"] ?? "",
            "icon": frontmatter["icon"] ?? "⚡",
            "system_prompt": body,
        ]
        return skill
    }

    func testParseStandardSkillMD() {
        let md = """
        ---
        name: Code Review
        description: Reviews code for quality
        icon: 🔍
        ---
        You are a code reviewer. Analyze the given code for:
        - Bugs
        - Performance issues
        - Best practices
        """

        let result = parseSkillMD(md)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["name"] as? String, "Code Review")
        XCTAssertEqual(result?["description"] as? String, "Reviews code for quality")
        XCTAssertEqual(result?["icon"] as? String, "🔍")
        XCTAssertTrue((result?["system_prompt"] as? String)?.contains("code reviewer") == true)
    }

    func testParseSkillMDWithoutFrontmatter() {
        let md = "You are a helpful assistant that translates text."

        let result = parseSkillMD(md, folderName: "translator.md")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["name"] as? String, "translator")
        XCTAssertEqual(result?["icon"] as? String, "⚡")
        XCTAssertEqual(result?["system_prompt"] as? String, md)
    }

    func testParseSkillMDMinimalFrontmatter() {
        let md = """
        ---
        name: MySkill
        ---
        Do something useful.
        """

        let result = parseSkillMD(md)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["name"] as? String, "MySkill")
        XCTAssertEqual(result?["description"] as? String, "")
        XCTAssertEqual(result?["icon"] as? String, "⚡")
    }

    func testParseEmptyContent() {
        let result = parseSkillMD("")
        XCTAssertNil(result, "空内容应返回 nil")
    }

    func testParseSkillMDWithChineseContent() {
        let md = """
        ---
        name: 代码审查助手
        description: 帮你审查代码质量
        icon: 🦞
        ---
        你是一个专业的代码审查助手。请仔细检查以下代码：
        1. 安全漏洞
        2. 性能问题
        3. 代码规范
        """

        let result = parseSkillMD(md)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["name"] as? String, "代码审查助手")
        XCTAssertTrue((result?["system_prompt"] as? String)?.contains("安全漏洞") == true)
    }

    func testFolderNameFallback() {
        let md = """
        ---
        description: No name field
        ---
        System prompt content.
        """

        let result = parseSkillMD(md, folderName: "my-custom-skill")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["name"] as? String, "my-custom-skill", "无 name 时应使用文件夹名")
    }
}
