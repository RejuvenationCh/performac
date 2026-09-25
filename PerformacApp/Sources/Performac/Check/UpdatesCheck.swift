// Check/UpdatesCheck.swift: the version comparison behind the update prompt. String
// equality or string order would offer 0.9.0 over 0.10.0, or offer nothing at all.
import Foundation

enum UpdatesCheck {
    @MainActor
    static func run(_ c: CheckSuite) async {
        c.true_("updates: patch is newer", Updates.isNewer("v0.1.1", than: "0.1.0"))
        c.true_("updates: 0.10 beats 0.9 numerically", Updates.isNewer("0.10.0", than: "0.9.0"))
        c.false_("updates: 0.9 does not beat 0.10", Updates.isNewer("0.9.0", than: "0.10.0"))
        c.false_("updates: same version is not newer", Updates.isNewer("v1.2.3", than: "1.2.3"))
        c.false_("updates: older is not newer", Updates.isNewer("v1.0.0", than: "1.2.0"))
        c.false_("updates: missing patch equals .0", Updates.isNewer("v1.2", than: "1.2.0"))
        c.true_("updates: release beats its rc", Updates.isNewer("1.0.0", than: "1.0.0-rc.1"))
        c.false_("updates: rc does not beat its release", Updates.isNewer("1.0.0-rc.1", than: "1.0.0"))
        c.true_("updates: rc.10 beats rc.2", Updates.isNewer("1.0.0-rc.10", than: "1.0.0-rc.2"))
        c.false_("updates: build metadata never orders", Updates.isNewer("1.0.0+abc", than: "1.0.0"))
        c.false_("updates: unparseable tag is never offered", Updates.isNewer("latest", than: "0.1.0"))
        c.eq("updates: version text drops the v", Updates.parse("v0.2.0").text, "0.2.0")

        let json = #"{"tag_name":"v0.2.0","body":"- Faster scans","html_url":"https://github.com/x/y/releases/tag/v0.2.0","draft":false}"#
        let r = try? JSONDecoder().decode(Release.self, from: Data(json.utf8))
        c.eq("updates: decodes a GitHub release", r?.version, "0.2.0")
        c.eq("updates: keeps the release notes", r?.body, "- Faster scans")
        c.true_("updates: no assets decodes as nil", r?.assets == nil)

        let withZip = #"{"tag_name":"v0.2.0","html_url":"u","assets":[{"name":"Performac.zip","browser_download_url":"https://x/Performac.zip","size":1}]}"#
        let z = try? JSONDecoder().decode(Release.self, from: Data(withZip.utf8))
        c.eq("updates: finds the release zip", z?.assets?.first(where: { $0.name == Updates.assetName })?.browser_download_url, "https://x/Performac.zip")
    }
}
