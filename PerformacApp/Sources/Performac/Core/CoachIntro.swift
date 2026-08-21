// CoachIntro.swift — the Digest's opening paragraph, written by Gemini.
//
// Same model and endpoint as Attention Dashboard's Day Briefing (gemini-flash-latest).
//
// Two deliberate constraints:
//
// 1. PRIVACY. Only each finding's severity, headline and why-line are sent. Never the
//    detail field or link targets, which carry absolute paths like
//    /Users/.../UC/Projects/Oweek/... — sending those would hand Google a map of the
//    user's project folders to write one paragraph. Headlines carry app names and sizes,
//    which is all the model needs.
//
// 2. THE MODEL NEVER OWNS A NUMBER. It restates findings that were already computed
//    deterministically. If the call fails, is not configured, or returns nothing, the
//    Digest falls back to its templated summary and nothing breaks.
import Foundation

enum CoachIntro {
    /// Outside the repo and outside the app bundle, so it is never committed or shipped.
    static var keyPath: String {
        NSHomeDirectory() + "/Library/Application Support/com.chris.performac.v2/gemini.key"
    }

    static var apiKey: String? {
        guard let raw = try? String(contentsOfFile: keyPath, encoding: .utf8) else { return nil }
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    static var isConfigured: Bool { apiKey != nil }

    /// Findings reduced to what the model may see.
    static func buildPrompt(_ rows: [(severity: String, headline: String, why: String)]) -> String {
        let list = rows.isEmpty
            ? "(nothing is currently worth reporting)"
            : rows.map { "- [\($0.severity)] \($0.headline). \($0.why)" }.joined(separator: "\n")
        return """
        You are writing the opening paragraph of a weekly Mac health digest for one person, \
        the owner of this machine. He edits video and photography, so his caches are large by \
        nature and that is normal, not a problem to solve.

        Findings, already measured. These are the only facts you have:
        \(list)

        Write one short paragraph, at most 120 words.

        Rules, all of them strict:
        - Plain text only. No markdown, no bullet points, no bold, no headings.
        - Never use an em dash or an en dash. Use a comma, a full stop, or the word "and".
        - Never invent a number, a size, a date or a percentage. Use only figures listed above, \
        and if none are listed, use none.
        - Never suggest deleting something the findings do not already suggest deleting.
        - Never claim anything is safe to remove. That judgement is not yours to make.
        - If a finding says to leave something alone, agree with it.
        - Warm and direct, like a knowledgeable friend. No greetings, no sign off, no emoji.
        - If there is nothing worth reporting, say so plainly in one or two sentences.
        """
    }

    /// Model output is prose, so treat it as prose: strip the punctuation we forbade rather
    /// than trusting the instruction, and cap the length.
    static func sanitize(_ text: String) -> String {
        var t = text
            .replacingOccurrences(of: "—", with: ", ")
            .replacingOccurrences(of: "–", with: ", ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "##", with: "")
            .replacingOccurrences(of: " , ", with: ", ")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 900 { t = String(t.prefix(900)) }
        return t
    }

    static func fetch(prompt: String) async -> String? {
        guard let key = apiKey,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent?key=\(key)")
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": String(prompt.prefix(8000))]]]],
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = obj["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return sanitize(text)
    }
}
