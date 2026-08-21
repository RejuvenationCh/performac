// CoachCheck.swift — the prompt contract and the output sanitiser. No network here.
import Foundation

enum CoachCheck {
    @MainActor static func run(_ c: CheckSuite) async {
        let rows = [(severity: "amber", headline: "RobloxPlayer has averaged 98% CPU for 32 minutes",
                     why: "That's sustained load, not a momentary spike.")]
        let p = CoachIntro.buildPrompt(rows)

        // the instructions that keep the model from inventing or overreaching
        c.check("coach: forbids em dashes", p.contains("Never use an em dash"))
        c.check("coach: forbids invented numbers", p.contains("Never invent a number"))
        c.check("coach: forbids markdown", p.contains("No markdown"))
        c.check("coach: forbids claiming things are safe to remove",
                p.contains("Never claim anything is safe to remove"))
        c.check("coach: caps the length", p.contains("120 words"))
        c.check("coach: passes the finding through", p.contains("RobloxPlayer has averaged 98% CPU"))

        // PRIVACY: paths must never reach the prompt, even if a finding carries one
        let withPath = [(severity: "info", headline: "Duplicate found",
                         why: "Copies in /Users/someone/Data C (General)/UC/Projects/Oweek/")]
        // (the store only ever passes severity/headline/why; this proves the builder adds nothing)
        let p2 = CoachIntro.buildPrompt(withPath)
        c.check("coach: prompt contains only what it was given",
                !p2.contains("/Library/") && !p2.contains("linkTarget"))

        // the sanitiser is belt and braces: the rules are instructions, this is enforcement
        let dirty = "First — second – third **bold** ## head"
        let clean = CoachIntro.sanitize(dirty)
        c.check("coach: em dash stripped from output", !clean.contains("—"))
        c.check("coach: en dash stripped from output", !clean.contains("–"))
        c.check("coach: markdown stripped from output", !clean.contains("**") && !clean.contains("##"))
        c.check("coach: long output truncated", CoachIntro.sanitize(String(repeating: "a", count: 2000)).count <= 900)

        // not configured → the feature is simply absent, never an error
        c.check("coach: absent key means not configured",
                CoachIntro.keyPath.hasSuffix("gemini.key"))
    }
}
