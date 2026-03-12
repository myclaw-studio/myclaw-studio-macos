import Foundation
import CryptoKit

// MARK: - Memory Manager

final class SwiftMemoryManager {
    static let shared = SwiftMemoryManager()

    private let dataDir: URL
    private let chatLogDir: URL

    // Storage
    private var subCore: [[String: Any]] = []
    private var general: [[String: Any]] = []
    private var coreMemory: [String: Any] = [:]
    private var summaries: [[String: Any]] = []
    private var diaryEntries: [[String: Any]] = []

    // State
    private var coreDirty = false
    private var lastCoreGenerated: Date? = nil
    private let coreMemoryInterval: TimeInterval = 7200 // 2 hours

    // Constants
    private let windowSize = 100
    private let compressThreshold = 100
    private let maxSummaries = 5
    private let subCoreTypes: Set<String> = ["identity", "contact", "preference", "habit", "skill", "goal", "value"]
    private let generalTypes: Set<String> = ["task", "event", "fact", "project"]

    private let queue = DispatchQueue(label: "memory-manager")

    private init() {
        dataDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aichat")
        chatLogDir = dataDir.appendingPathComponent("chat_logs")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        loadAll()
        recalcAllWeights()
    }

    // MARK: - File Paths

    private var subCorePath: URL { dataDir.appendingPathComponent("sub_core_memories.json") }
    private var generalPath: URL { dataDir.appendingPathComponent("general_memories.json") }
    private var coreMemoryPath: URL { dataDir.appendingPathComponent("core_memory.json") }
    private var summariesPath: URL { dataDir.appendingPathComponent("summaries.json") }
    private var diaryPath: URL { dataDir.appendingPathComponent("diary_entries.json") }

    // MARK: - Load / Save

    private func loadAll() {
        subCore = loadJSON(subCorePath) as? [[String: Any]] ?? []
        general = loadJSON(generalPath) as? [[String: Any]] ?? []
        coreMemory = loadJSONObj(coreMemoryPath) ?? [:]
        summaries = loadJSON(summariesPath) as? [[String: Any]] ?? []
        diaryEntries = loadJSON(diaryPath) as? [[String: Any]] ?? []

        // Record initial file mod times
        let fm = FileManager.default
        for path in [subCorePath, generalPath, coreMemoryPath, summariesPath, diaryPath] {
            if let attrs = try? fm.attributesOfItem(atPath: path.path),
               let modDate = attrs[.modificationDate] as? Date {
                fileModTimes[path] = modDate
            }
        }

        if let genAt = coreMemory["generated_at"] as? String {
            let f = ISO8601DateFormatter()
            lastCoreGenerated = f.date(from: genAt)
        }
    }

    private func loadJSON(_ path: URL) -> Any? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func loadJSONObj(_ path: URL) -> [String: Any]? {
        loadJSON(path) as? [String: Any]
    }

    private func writeJSON(_ path: URL, _ obj: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        try? data.write(to: path, options: .atomic)
    }

    private func saveSubCore() { writeJSON(subCorePath, subCore); fileModTimes[subCorePath] = Date() }
    private func saveGeneral() { writeJSON(generalPath, general); fileModTimes[generalPath] = Date() }
    private func saveCoreMemory() { writeJSON(coreMemoryPath, coreMemory); fileModTimes[coreMemoryPath] = Date() }
    private func saveSummaries() { writeJSON(summariesPath, summaries); fileModTimes[summariesPath] = Date() }
    private func saveDiary() { writeJSON(diaryPath, diaryEntries); fileModTimes[diaryPath] = Date() }

    // MARK: - Auto-reload (detect external writes from Python)

    private var fileModTimes: [URL: Date] = [:]

    /// Reload any JSON files modified externally (e.g. by Python extract_and_store)
    private func reloadIfNeeded() {
        let fm = FileManager.default
        func modTime(_ path: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        }
        func needsReload(_ path: URL) -> Bool {
            guard let diskTime = modTime(path) else { return false }
            guard let cachedTime = fileModTimes[path] else { return true }
            return diskTime > cachedTime
        }

        if needsReload(subCorePath) {
            subCore = loadJSON(subCorePath) as? [[String: Any]] ?? subCore
            fileModTimes[subCorePath] = modTime(subCorePath) ?? Date()
        }
        if needsReload(generalPath) {
            general = loadJSON(generalPath) as? [[String: Any]] ?? general
            fileModTimes[generalPath] = modTime(generalPath) ?? Date()
        }
        if needsReload(coreMemoryPath) {
            coreMemory = loadJSONObj(coreMemoryPath) ?? coreMemory
            fileModTimes[coreMemoryPath] = modTime(coreMemoryPath) ?? Date()
        }
        if needsReload(summariesPath) {
            summaries = loadJSON(summariesPath) as? [[String: Any]] ?? summaries
            fileModTimes[summariesPath] = modTime(summariesPath) ?? Date()
        }
        if needsReload(diaryPath) {
            diaryEntries = loadJSON(diaryPath) as? [[String: Any]] ?? diaryEntries
            fileModTimes[diaryPath] = modTime(diaryPath) ?? Date()
        }
    }

    // MARK: - Weight Calculation

    static func calcWeight(daysSinceLastHit: Double, hitCount: Int) -> Double {
        let timeScore = 1.0 / (1.0 + daysSinceLastHit * 0.15)
        let freqScore = min(log2(Double(hitCount + 1)) / 4.0, 1.0)
        return ((timeScore * 0.6 + freqScore * 0.4) * 1000).rounded() / 1000
    }

    private func touch(_ mem: inout [String: Any]) {
        let count = (mem["hit_count"] as? Int ?? 0) + 1
        mem["hit_count"] = count
        mem["last_hit"] = ISO8601DateFormatter().string(from: Date())
        mem["weight"] = Self.calcWeight(daysSinceLastHit: 0, hitCount: count)
    }

    private func recalcAllWeights() {
        let now = Date()
        func recalc(_ store: inout [[String: Any]]) {
            for i in store.indices {
                let lastHit = store[i]["last_hit"] as? String ?? store[i]["created_at"] as? String ?? ""
                let hitCount = store[i]["hit_count"] as? Int ?? 0
                var days = 0.0
                if let d = parseDate(lastHit) {
                    days = max(now.timeIntervalSince(d) / 86400, 0)
                }
                store[i]["weight"] = Self.calcWeight(daysSinceLastHit: days, hitCount: hitCount)
            }
        }
        recalc(&subCore)
        recalc(&general)
    }

    private func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        // Try Python-style datetime without timezone
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        df.locale = Locale(identifier: "en_US_POSIX")
        if let d = df.date(from: s) { return d }
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return df.date(from: s)
    }

    // MARK: - Sliding Window

    func getWindow(history: [[String: Any]]) -> [[String: Any]] {
        if history.count > windowSize {
            return Array(history.suffix(windowSize))
        }
        return history
    }

    // MARK: - CRUD

    func add(text: String, type: String = "fact", tier: String = "general") -> String {
        return queue.sync {
            reloadIfNeeded()
            let resolvedTier = subCoreTypes.contains(type) ? "sub_core" : (generalTypes.contains(type) ? "general" : tier)
            let id = UUID().uuidString
            let now = isoNow()
            let embedding = hashEmbed(text)
            let mem: [String: Any] = [
                "id": id,
                "text": text,
                "type": type,
                "embedding": embedding,
                "created_at": now,
                "last_hit": now,
                "hit_count": 0,
                "weight": Self.calcWeight(daysSinceLastHit: 0, hitCount: 0),
            ]

            if resolvedTier == "sub_core" {
                if !isDuplicateIn(text: text, embedding: embedding, store: subCore) {
                    subCore.append(mem)
                    saveSubCore()
                }
            } else {
                if !isDuplicateIn(text: text, embedding: embedding, store: general) {
                    general.append(mem)
                    saveGeneral()
                }
            }
            coreDirty = true
            return id
        }
    }

    func listAll(limit: Int = 200) -> [[String: Any]] {
        return queue.sync {
            reloadIfNeeded()
            // Sub-core first, then general, sorted by weight desc within each
            let sc = subCore.sorted { ($0["weight"] as? Double ?? 0) > ($1["weight"] as? Double ?? 0) }
                .map { m -> [String: Any] in
                    var r = m; r["tier"] = "sub_core"; r.removeValue(forKey: "embedding"); return r
                }
            let gen = general.sorted { ($0["weight"] as? Double ?? 0) > ($1["weight"] as? Double ?? 0) }
                .map { m -> [String: Any] in
                    var r = m; r["tier"] = "general"; r.removeValue(forKey: "embedding"); return r
                }
            return Array((sc + gen).prefix(limit))
        }
    }

    func delete(memoryId: String) -> Bool {
        return queue.sync {
            let before = subCore.count + general.count
            subCore.removeAll { ($0["id"] as? String) == memoryId }
            general.removeAll { ($0["id"] as? String) == memoryId }
            let after = subCore.count + general.count
            if before != after {
                saveSubCore(); saveGeneral()
                return true
            }
            return false
        }
    }

    func clearAll() {
        queue.sync {
            subCore = []; general = []; coreMemory = [:]; summaries = []
            saveSubCore(); saveGeneral(); saveCoreMemory(); saveSummaries()
        }
    }

    // MARK: - Deduplication

    func deduplicate() -> Int {
        return queue.sync {
            let before = subCore.count + general.count
            subCore = deduplicateStore(subCore)
            general = deduplicateStore(general)
            let removed = before - (subCore.count + general.count)
            if removed > 0 {
                saveSubCore(); saveGeneral()
            }
            return removed
        }
    }

    private func deduplicateStore(_ store: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for mem in store {
            let text = mem["text"] as? String ?? ""
            let emb = mem["embedding"] as? [Double] ?? []
            if !isDuplicateIn(text: text, embedding: emb, store: result) {
                result.append(mem)
            }
        }
        return result
    }

    private func isDuplicateIn(text: String, embedding: [Double], store: [[String: Any]]) -> Bool {
        let lower = text.lowercased()
        let queryBigrams = makeBigrams(lower)
        for m in store {
            let mText = (m["text"] as? String ?? "").lowercased()
            // Exact match
            if mText == lower { return true }
            // Substring containment (either direction)
            if lower.count >= 4 && mText.count >= 4 {
                if lower.contains(mText) || mText.contains(lower) { return true }
            }
            // Bigram Jaccard similarity > 0.65
            let mBigrams = makeBigrams(mText)
            let inter = queryBigrams.intersection(mBigrams).count
            let union = queryBigrams.union(mBigrams).count
            if union > 0 && Double(inter) / Double(union) > 0.65 { return true }
        }
        return false
    }

    private func makeBigrams(_ text: String) -> Set<String> {
        let chars = Array(text)
        guard chars.count >= 2 else { return Set(chars.map(String.init)) }
        var result = Set<String>()
        for i in 0..<chars.count - 1 {
            result.insert(String([chars[i], chars[i + 1]]))
        }
        return result
    }

    // MARK: - Hash Embedding (MD5-based, matches Python _hash_embed)

    private func hashEmbed(_ text: String, dim: Int = 128) -> [Double] {
        var result = [Double](repeating: 0, count: dim)
        for i in 0..<dim {
            let input = "\(i):\(text)"
            let digest = Insecure.MD5.hash(data: Data(input.utf8))
            let bytes = Array(digest)
            // Take first 4 bytes as little-endian uint32, same as Python int.from_bytes(h[:4], "little")
            let val = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            result[i] = Double(val) / Double(UInt32.max) * 2.0 - 1.0
        }
        // L2 normalize
        let norm = sqrt(result.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            for i in result.indices { result[i] /= norm }
        }
        return result
    }

    // MARK: - Search (char n-gram based, Phase 5a)

    func search(query: String, subCoreK: Int = 5, generalK: Int = 5,
                mode: String = "search", typeFilter: String? = nil) -> [[String: Any]] {
        return queue.sync {
            reloadIfNeeded()
            let results: [[String: Any]]
            if mode == "lookup" {
                results = lookupSearch(query: query, subCoreK: subCoreK, generalK: generalK, typeFilter: typeFilter)
            } else {
                // char n-gram search
                let scResults = charSearch(query: query, store: &subCore, k: subCoreK, tier: "sub_core", typeFilter: typeFilter)
                let genResults = charSearch(query: query, store: &general, k: generalK, tier: "general", typeFilter: typeFilter)
                results = scResults + genResults
            }
            // Persist touch updates
            saveSubCore()
            saveGeneral()
            return results
        }
    }

    private func charSearch(query: String, store: inout [[String: Any]], k: Int, tier: String, typeFilter: String?) -> [[String: Any]] {
        var scored: [(mem: [String: Any], score: Double)] = []
        for i in store.indices {
            if let tf = typeFilter, (store[i]["type"] as? String) != tf { continue }
            let text = store[i]["text"] as? String ?? ""
            let charScore = charMatchScore(query: query, text: text)
            let weight = store[i]["weight"] as? Double ?? 0
            let finalScore = charScore * 0.7 + weight * 0.3
            if finalScore > 0.1 {
                touch(&store[i])
                var result = store[i]
                result["tier"] = tier
                result.removeValue(forKey: "embedding")
                scored.append((result, finalScore))
            }
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(k).map { $0.mem })
    }

    private func lookupSearch(query: String, subCoreK: Int, generalK: Int, typeFilter: String?) -> [[String: Any]] {
        let keywords = query.lowercased().split(separator: " ").map(String.init)
        func match(_ store: inout [[String: Any]], _ k: Int, _ tier: String) -> [[String: Any]] {
            var results: [[String: Any]] = []
            for i in store.indices {
                if let tf = typeFilter, (store[i]["type"] as? String) != tf { continue }
                let text = (store[i]["text"] as? String ?? "").lowercased()
                if keywords.allSatisfy({ text.contains($0) }) {
                    touch(&store[i])
                    var r = store[i]; r["tier"] = tier; r.removeValue(forKey: "embedding")
                    results.append(r)
                }
            }
            results.sort { ($0["weight"] as? Double ?? 0) > ($1["weight"] as? Double ?? 0) }
            return Array(results.prefix(k))
        }
        return match(&subCore, subCoreK, "sub_core") + match(&general, generalK, "general")
    }

    private func charMatchScore(query: String, text: String) -> Double {
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        guard !q.isEmpty && !t.isEmpty else { return 0 }

        // Char set similarity (40%)
        let qSet = Set(q)
        let tSet = Set(t)
        let inter = qSet.intersection(tSet).count
        let union = qSet.union(tSet).count
        let charSim = union > 0 ? Double(inter) / Double(union) : 0

        // Bigram similarity (60%)
        func bigrams(_ arr: [Character]) -> Set<String> {
            guard arr.count >= 2 else { return Set(arr.map(String.init)) }
            var s = Set<String>()
            for i in 0..<arr.count - 1 {
                s.insert(String([arr[i], arr[i+1]]))
            }
            return s
        }
        let qBi = bigrams(q)
        let tBi = bigrams(t)
        let biInter = qBi.intersection(tBi).count
        let biUnion = qBi.union(tBi).count
        let biSim = biUnion > 0 ? Double(biInter) / Double(biUnion) : 0

        return charSim * 0.4 + biSim * 0.6
    }

    // MARK: - Core Memory

    func getCoreMemory() -> String {
        return queue.sync {
            reloadIfNeeded()
            return _getCoreMemory()
        }
    }

    /// Internal version without lock (caller must hold queue)
    private func _getCoreMemory() -> String {
        var parts: [String] = []
        let en = AppConfig.language == "en"
        if let pinned = coreMemory["pinned"] as? String, !pinned.isEmpty {
            parts.append(en ? "[User Profile]\n\(pinned)" : "[主人档案]\n\(pinned)")
        }
        if let trending = coreMemory["trending"] as? String, !trending.isEmpty {
            parts.append(en ? "[Recent Focus]\n\(trending)" : "[近期关注]\n\(trending)")
        }
        if parts.isEmpty {
            return fallbackCoreMemory()
        }
        return parts.joined(separator: "\n\n")
    }

    private func fallbackCoreMemory() -> String {
        // Use top-weighted sub_core memories as fallback
        let sorted = subCore.sorted { ($0["weight"] as? Double ?? 0) > ($1["weight"] as? Double ?? 0) }
        let top = sorted.prefix(10)
        if top.isEmpty { return "" }
        var lines = [AppConfig.language == "en" ? "[User Profile (auto-generated)]" : "[主人档案（自动生成）]"]
        for m in top {
            lines.append("- \(m["text"] as? String ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    func shouldRefreshCoreMemory() -> Bool {
        guard coreDirty else { return false }
        if let last = lastCoreGenerated {
            return Date().timeIntervalSince(last) >= coreMemoryInterval
        }
        return true
    }

    func generateCoreMemory(provider: LLMProvider) async {
        // Pinned: from top 20 sub_core by weight
        let topSub: [[String: Any]] = queue.sync {
            Array(subCore.sorted { ($0["weight"] as? Double ?? 0) > ($1["weight"] as? Double ?? 0) }.prefix(20))
        }
        if !topSub.isEmpty {
            let items = topSub.map { "- \($0["text"] as? String ?? "")" }.joined(separator: "\n")
            let en = AppConfig.language == "en"
            let prompt = en ? """
                Here are long-term memory entries about the user:
                \(items)

                Distill these into a concise user profile:
                - Merge duplicate information
                - Keep all specific data (name, email, preferences, etc.)
                - Remove vague descriptions
                - Under 500 words, organized in paragraphs
                - Output the profile directly, no title or prefix
                """ : """
                以下是关于用户的长期记忆条目：
                \(items)

                请将这些信息提炼为一份简洁的「用户档案」：
                - 合并重复信息
                - 保留所有具体数据（姓名、邮箱、偏好等）
                - 去除笼统描述
                - 500字以内，分段落组织
                - 直接输出档案内容，不要加标题或前缀
                """
            if let pinned = try? await provider.singleCall(prompt: prompt, system: en ? "You are an information organizing assistant." : "你是一个信息整理助手。") {
                queue.sync { coreMemory["pinned"] = pinned.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }

        // Trending: from recent 2 days of general memories
        let twoDaysAgo = Date().addingTimeInterval(-172800)
        let recent: [[String: Any]] = queue.sync {
            general.filter { m in
                guard let dateStr = m["created_at"] as? String, let d = parseDate(dateStr) else { return false }
                return d >= twoDaysAgo
            }
        }
        if !recent.isEmpty {
            let items = recent.map { "- \($0["text"] as? String ?? "")" }.joined(separator: "\n")
            let en = AppConfig.language == "en"
            let prompt = en ? """
                Here are the user's activity records from the past two days:
                \(items)

                Summarize as "Recent Focus":
                - Group by topic
                - Highlight ongoing tasks and interests
                - Under 300 words
                - Output content directly, no title
                """ : """
                以下是用户近两天的活动记录：
                \(items)

                请总结为「近期关注」：
                - 按主题归类
                - 突出正在进行的任务和兴趣点
                - 300字以内
                - 直接输出内容，不要加标题
                """
            if let trending = try? await provider.singleCall(prompt: prompt, system: en ? "You are an information organizing assistant." : "你是一个信息整理助手。") {
                queue.sync { coreMemory["trending"] = trending.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }

        queue.sync {
            coreMemory["generated_at"] = isoNow()
            lastCoreGenerated = Date()
            coreDirty = false
            saveCoreMemory()
        }
        NSLog("[MemoryManager] Core memory regenerated")
    }

    // MARK: - Summary Compression

    func maybeCompress(history: [[String: Any]], provider: LLMProvider) async -> Bool {
        // Read compression state under lock
        let (start, end, batch): (Int, Int, [[String: Any]]) = queue.sync {
            let coveredThrough = summaries.last.flatMap { $0["through_message"] as? Int } ?? 0
            // Guard against stale index (history cleared/shortened externally)
            guard coveredThrough <= history.count else {
                NSLog("[MemoryManager] maybeCompress: coveredThrough(%d) > history.count(%d), resetting", coveredThrough, history.count)
                return (-1, -1, [])
            }
            let uncompressed = history.count - coveredThrough
            guard uncompressed >= compressThreshold else { return (-1, -1, []) }
            let s = coveredThrough
            let e = min(s + compressThreshold, history.count)
            return (s, e, Array(history[s..<e]))
        }
        guard start >= 0 else { return false }

        // Format messages for LLM
        let convo = batch.compactMap { m -> String? in
            let role = m["role"] as? String ?? "user"
            let content: String
            if let s = m["content"] as? String { content = s }
            else if let blocks = m["content"] as? [[String: Any]] {
                content = blocks.compactMap { b -> String? in
                    (b["type"] as? String) == "text" ? b["text"] as? String : nil
                }.joined(separator: " ")
            } else { return nil }
            return "\(role): \(content.prefix(500))"
        }.joined(separator: "\n")

        let en = AppConfig.language == "en"
        let lastSummary: String? = queue.sync { summaries.last?["text"] as? String }
        var prompt: String
        if let lastSummary = lastSummary {
            prompt = en ? """
                Previous summary:
                \(lastSummary)

                New conversation:
                \(convo)

                Generate a combined summary:
                - Merge the previous summary with the new conversation
                - Under 150 words, third person
                - Keep valuable info (user preferences, important decisions, key events)
                - Output the summary directly
                """ : """
                前一摘要：
                \(lastSummary)

                新对话内容：
                \(convo)

                请生成综合摘要：
                - 结合前一摘要和新对话
                - 150字以内，第三人称
                - 保留有价值的信息（用户偏好、重要决定、关键事件）
                - 直接输出摘要内容
                """
        } else {
            prompt = en ? """
                Conversation:
                \(convo)

                Generate a summary:
                - Under 150 words, third person
                - Keep valuable info (user preferences, important decisions, key events)
                - Output the summary directly
                """ : """
                对话内容：
                \(convo)

                请生成摘要：
                - 150字以内，第三人称
                - 保留有价值的信息（用户偏好、重要决定、关键事件）
                - 直接输出摘要内容
                """
        }

        guard let summaryText = try? await provider.singleCall(prompt: prompt, system: en ? "You are a conversation summarizer." : "你是一个对话摘要助手。") else {
            return false
        }

        let entry: [String: Any] = [
            "id": UUID().uuidString,
            "text": summaryText.trimmingCharacters(in: .whitespacesAndNewlines),
            "through_message": end,
            "created_at": isoNow(),
        ]
        queue.sync {
            summaries.append(entry)
            if summaries.count > maxSummaries {
                summaries = Array(summaries.suffix(maxSummaries))
            }
            saveSummaries()
        }
        NSLog("[MemoryManager] Compressed messages \(start)-\(end), summaries=\(summaries.count)")
        return true
    }

    // MARK: - Category Compression

    func compressCategory(type: String, provider: LLMProvider) async -> [String: Any] {
        let isSubCore = subCoreTypes.contains(type)
        let items: [[String: Any]] = queue.sync {
            let store = isSubCore ? subCore : general
            return store.filter { ($0["type"] as? String) == type }
        }
        guard items.count >= 3 else {
            return ["before": items.count, "after": items.count, "error": "条目不足3条，无需压缩"]
        }

        let texts = items.map { "- \($0["text"] as? String ?? "")" }.joined(separator: "\n")
        let prompt = """
            以下是类型为「\(type)」的记忆条目：
            \(texts)

            请压缩提纯：
            1. 合并重复或相似的信息
            2. 保留所有具体数据（邮箱、人名、数字等）
            3. 去除笼统描述
            4. 每条用完整陈述句
            5. 用 JSON 数组格式返回：["条目1", "条目2", ...]
            """

        guard let result = try? await provider.singleCall(prompt: prompt, system: "你是一个信息整理助手。只返回JSON数组，不要其他内容。"),
              let jsonData = result.data(using: .utf8),
              let newTexts = try? JSONSerialization.jsonObject(with: jsonData) as? [String] else {
            return ["before": items.count, "after": items.count, "error": "LLM 返回格式错误"]
        }

        // Remove old items of this type, add new ones
        queue.sync {
            if isSubCore {
                subCore.removeAll { ($0["type"] as? String) == type }
                for t in newTexts {
                    let mem = makeMemory(text: t, type: type)
                    subCore.append(mem)
                }
                saveSubCore()
            } else {
                general.removeAll { ($0["type"] as? String) == type }
                for t in newTexts {
                    let mem = makeMemory(text: t, type: type)
                    general.append(mem)
                }
                saveGeneral()
            }
            coreDirty = true
        }
        return ["before": items.count, "after": newTexts.count]
    }

    // MARK: - Diary

    func getDiaryEntries() -> [[String: Any]] {
        return queue.sync {
            reloadIfNeeded()
            return diaryEntries.sorted {
                ($0["date"] as? String ?? "") > ($1["date"] as? String ?? "")
            }
        }
    }

    func generateDiaryEntry(provider: LLMProvider, force: Bool = false, lang: String = "zh") async -> [String: Any]? {
        let today = todayString()

        // Check if already generated today (allow update if >2 hours since last generation)
        let shouldSkip: Bool = queue.sync {
            guard let existing = diaryEntries.first(where: { ($0["date"] as? String) == today }) else {
                return false
            }
            if force { return false }
            // Allow regeneration if >2 hours have passed since last diary
            if let genStr = existing["generated_at"] as? String, let genDate = parseDate(genStr) {
                return Date().timeIntervalSince(genDate) < 7200
            }
            return true
        }
        if shouldSkip {
            return nil
        }

        // Read recent chat logs
        let logFile = chatLogDir.appendingPathComponent("\(today).jsonl")
        var chatLines: [String] = []
        if let content = try? String(contentsOf: logFile, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            for line in lines.suffix(100) {
                if let data = line.data(using: .utf8),
                   let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let user = entry["user"] as? String ?? ""
                    let reply = entry["reply"] as? String ?? ""
                    if !user.isEmpty {
                        chatLines.append("用户: \(user.prefix(200))")
                        if !reply.isEmpty { chatLines.append("Clawbie: \(reply.prefix(200))") }
                    }
                }
            }
        }

        guard !chatLines.isEmpty else { return nil }

        let chatText = chatLines.joined(separator: "\n")
        let prompt: String
        if lang == "en" {
            prompt = """
                Based on today's conversations:
                \(chatText)

                Write a short diary entry from Clawbie's perspective:
                - First person, warm and natural tone
                - Record specific events, not vague emotions
                - 100-200 words
                - Return strict JSON: {"weather": "emoji", "mood": "one word", "content": "diary text"}
                """
        } else {
            prompt = """
                根据今天的对话记录：
                \(chatText)

                从 Clawbie 的角度写一篇简短日记：
                - 第一人称，语气温柔自然
                - 记录具体事件，不要空泛抒情
                - 100-200字
                - 返回严格 JSON：{"weather": "天气emoji", "mood": "一个词", "content": "日记正文"}
                """
        }

        guard let result = try? await provider.singleCall(prompt: prompt, system: lang == "en" ? "You are Clawbie writing a diary. Return only JSON." : "你是 Clawbie 在写日记。只返回 JSON。") else {
            return nil
        }

        // Parse JSON from LLM response
        guard let parsed = extractJSON(from: result) else {
            NSLog("[MemoryManager] Failed to parse diary JSON: \(result.prefix(200))")
            return nil
        }

        let entry: [String: Any] = [
            "id": UUID().uuidString,
            "date": today,
            "weather": parsed["weather"] ?? "☀️",
            "mood": parsed["mood"] ?? "neutral",
            "content": parsed["content"] ?? "",
            "generated_at": isoNow(),
        ]

        // Replace existing entry for today (covers both force and auto-update)
        queue.sync {
            diaryEntries.removeAll { ($0["date"] as? String) == today }
            diaryEntries.append(entry)
            saveDiary()
        }
        NSLog("[MemoryManager] Diary generated for \(today)")
        return entry
    }

    // MARK: - Memory Context (for system prompt)

    func buildContext(query: String = "") -> String {
        return queue.sync {
            reloadIfNeeded()
            var parts: [String] = []

            // Core memory (pinned + trending)
            let core = _getCoreMemory()
            if !core.isEmpty { parts.append(core) }

            // Summaries
            if !summaries.isEmpty {
                let summaryTexts = summaries.map { $0["text"] as? String ?? "" }.joined(separator: "\n")
                parts.append(AppConfig.language == "en" ? "[Chat History Summary]\n\(summaryTexts)" : "[历史摘要]\n\(summaryTexts)")
            }

            return parts.joined(separator: "\n\n")
        }
    }

    // MARK: - Post-Chat Processing

    func afterChat(userMessage: String, reply: String, history: [[String: Any]], provider: LLMProvider) async {
        // 1. Extract and store memories from this conversation
        await extractAndStore(userMessage: userMessage, reply: reply, provider: provider)

        // 2. Core memory refresh (if dirty and interval passed)
        if shouldRefreshCoreMemory() {
            await generateCoreMemory(provider: provider)
        }

        // 3. Summary compression
        _ = await maybeCompress(history: history, provider: provider)
    }

    // MARK: - Memory Extraction

    func extractAndStore(userMessage: String, reply: String, provider: LLMProvider) async {
        guard !userMessage.isEmpty, !reply.isEmpty else { return }

        let en = AppConfig.language == "en"
        let conversation = en ? "User: \(userMessage)\nAI: \(reply)" : "用户: \(userMessage)\nAI: \(reply)"

        // Build existing memories reference for dedup (read under lock)
        // Use top-weighted memories across both stores for better dedup coverage
        let existingCtx: String = queue.sync {
            reloadIfNeeded()
            let allMems = subCore + general
            if allMems.isEmpty { return "" }
            let sorted = allMems.sorted { ($0["weight"] as? Double ?? 0) > ($1["weight"] as? Double ?? 0) }
            let lines = sorted.prefix(80).map { "- \($0["text"] as? String ?? "")" }.joined(separator: "\n")
            return en
                ? "Existing memories (do not extract duplicate or highly similar content):\n\(lines)\n\n"
                : "已有记忆（不要重复提取相同或高度相似的内容）：\n\(lines)\n\n"
        }

        let prompt = en ? """
            Extract new information worth remembering long-term from the conversation. Return as a JSON array (max 5 items, return [] if nothing new).

            \(existingCtx)\
            Classification rules:
            - Sub-core memory (tier=sub_core): important persistent info about the user
              type options: identity, contact (must include specific contact info like email/phone), preference, habit, skill, goal, value
            - General memory (tier=general): temporary, one-time information
              type options: task, event, fact, project

            Extraction principles:
            - Must extract personal info the user actively mentions (family, career, hobbies, relationships, etc.). Generally trust the user; if it seems like an obvious joke, record the fact and note it may be a joke.
            - text should be a complete declarative sentence with the user as subject
            - Do not extract user's evaluations, expectations, or emotional reactions toward AI
            - Contact info must include specific details (email, phone, etc.)
            - Do not duplicate info already in existing memories

            JSON format: [{"text": "...", "tier": "sub_core|general", "type": "..."}]

            Conversation:
            \(conversation)

            JSON:
            """ : """
            从对话中提取值得长期记住的新信息，以JSON数组格式返回（最多5条，无新信息返回[]）。

            \(existingCtx)\
            分类规则：
            - 次核心记忆（tier=sub_core）：关于主人的重要持久信息
              type 可选：identity（身份背景）、contact（联系人+联系方式）、preference（偏好）、
              habit（习惯模式）、skill（能力专长）、goal（长期目标）、value（价值观性格）
            - 一般记忆（tier=general）：临时性、一次性的信息
              type 可选：task（任务）、event（事件）、fact（一般事实）、project（项目相关）

            提取原则：
            - 用户主动提及的个人信息必须提取（家庭、职业、爱好、关系等），根据当前情况判断，一般不要质疑，如果感觉用户明显在开玩笑，就记录下事实并备注，可能是个玩笑。
            - text 用完整陈述句，主语为用户
            - 不提取用户对AI的评价、期望、情绪反应（如「用户希望AI更准确」不要提取）
            - 联系人信息必须包含具体联系方式（邮箱、电话等）
            - 已有记忆中存在的信息不要重复提取

            JSON格式：[{"text": "...", "tier": "sub_core|general", "type": "..."}]

            对话：
            \(conversation)

            JSON：
            """

        let extractSystem = en
            ? "You are a memory extraction assistant. Extract key facts from conversations precisely. Always return a valid JSON array."
            : "你是一个记忆提取助手。从对话中精准提取关键事实。始终返回有效的JSON数组。"

        guard let result = try? await provider.singleCall(prompt: prompt, system: extractSystem),
              let startIdx = result.firstIndex(of: "["),
              let endIdx = result.lastIndex(of: "]") else {
            NSLog("[MemoryManager] extractAndStore: LLM returned no valid JSON array")
            return
        }
        NSLog("[MemoryManager] extractAndStore raw: %@", String(result.prefix(200)))

        let jsonStr = String(result[startIdx...endIdx])
        guard let jsonData = jsonStr.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            return
        }

        // Store extracted memories under lock
        let stored: [String] = queue.sync {
            reloadIfNeeded()
            var result: [String] = []
            for item in items.prefix(5) {
                guard let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                var tier = item["tier"] as? String ?? "general"
                var type = item["type"] as? String ?? "fact"

                // Validate tier/type
                if tier == "sub_core" {
                    if !subCoreTypes.contains(type) { type = "preference" }
                } else {
                    tier = "general"
                    if !generalTypes.contains(type) { type = "fact" }
                }

                let emb = hashEmbed(text)
                let store = tier == "sub_core" ? subCore : general
                if isDuplicateIn(text: text, embedding: emb, store: store) { continue }

                let mem = makeMemory(text: text, type: type)
                if tier == "sub_core" {
                    subCore.append(mem)
                } else {
                    general.append(mem)
                }
                result.append(text)
            }

            if !result.isEmpty {
                saveSubCore()
                saveGeneral()
                coreDirty = true
            }
            return result
        }

        if !stored.isEmpty {
            NSLog("[MemoryManager] Extracted \(stored.count) memories: \(stored.map { String($0.prefix(40)) })")
        }
    }

    // MARK: - Helpers

    private func isoNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func makeMemory(text: String, type: String) -> [String: Any] {
        let now = isoNow()
        return [
            "id": UUID().uuidString,
            "text": text,
            "type": type,
            "embedding": hashEmbed(text),
            "created_at": now,
            "last_hit": now,
            "hit_count": 0,
            "weight": Self.calcWeight(daysSinceLastHit: 0, hitCount: 0),
        ]
    }

    private func extractJSON(from text: String) -> [String: Any]? {
        // Try to find JSON object in text
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown code block
        if s.hasPrefix("```") {
            if let start = s.range(of: "{"), let end = s.range(of: "}", options: .backwards) {
                s = String(s[start.lowerBound...end.lowerBound])
            }
        }
        // Find first { to last }
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") {
            let jsonStr = String(s[start...end])
            if let data = jsonStr.data(using: .utf8) {
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        }
        return nil
    }
}
