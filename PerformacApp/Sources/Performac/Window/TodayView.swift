import SwiftUI

struct TodayView: View {
    var findings: [Finding] = Sample.findings
    var quitAction: (String) -> Void = { _ in }
    var body: some View {
        Page(title: "Today", subtitle: "Live view — drives, thermals, and anything time-sensitive.") {
            if findings.isEmpty { QuietState() }
            else {
                ScrollView {
                    VStack(spacing: PC.gutter) {
                        ForEach(findings) { CoachCardView(finding: $0, onQuit: quitAction) }
                    }
                    .padding(.horizontal, PC.stack).padding(.bottom, PC.stack)
                }
            }
        }
    }
}

/// The app's most common state. It must look deliberate, never broken or unloaded.
struct QuietState: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44)).foregroundStyle(PC.green)
            Text("Nothing worth doing").font(.pcHeadline).foregroundStyle(PC.ink)
                .padding(.top, PC.gutter)
            Text("Performac has been watching for 6 days. Caches are in normal range,\ndrives are steady, free space is holding.")
                .font(.pcBody).foregroundStyle(PC.ink2)
                .multilineTextAlignment(.center).lineSpacing(2).padding(.top, PC.s1)
            HStack(spacing: PC.s2) {
                QuietTile("Free space", "66 GB")
                QuietTile("Largest cache", "29.8 GB")
                QuietTile("Drives steady", "6 days")
                QuietTile("Last scan", "2 hours ago")
            }
            .padding(.top, PC.stack + 4)
            Spacer()
            Text("Last checked 30 seconds ago").font(.pcSmall).foregroundStyle(PC.meta)
                .padding(.bottom, PC.stack)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct QuietTile: View {
    let label: String, value: String
    init(_ l: String, _ v: String) { label = l; value = v }
    var body: some View {
        VStack(spacing: 3) {
            Text(label).font(.pcLabel).foregroundStyle(PC.meta)
            Text(value).font(.pcNum).fontWeight(.medium).foregroundStyle(PC.ink)
        }
        .frame(width: 108).padding(.vertical, PC.s2 + 2)
        .background(PC.surface).clipShape(RoundedRectangle(cornerRadius: PC.rLg))
        .overlay(RoundedRectangle(cornerRadius: PC.rLg).stroke(PC.hairline, lineWidth: 1))
    }
}

struct DigestView: View {
    var findings: [Finding] = Sample.findings
    var quitAction: (String) -> Void = { _ in }
    var body: some View {
        Page(title: "Digest", subtitle: "Weekly read — the trends behind the cards.") {
            ScrollView {
                VStack(alignment: .leading, spacing: PC.gutter) {
                    VStack(alignment: .leading, spacing: PC.s2) {
                        SectionHeader(text: "This week")
                        Text("Hey, quick look at your Mac this week. RobloxPlayer has been averaging 99% CPU for the last 46 minutes, which is sustained load rather than a quick spike, so if you're not actually using it, quitting it from Activity Monitor is worth doing. Everything else looks fine. Resolve's media cache is sitting at 27.7 GB, but it was last written 15 days ago, still under your 21-day line, so leave it alone.")
                            .font(.pcBody).foregroundStyle(PC.ink2).lineSpacing(3)
                            .frame(maxWidth: 620, alignment: .leading)
                    }
                    .padding(PC.gutter).frame(maxWidth: .infinity, alignment: .leading).pcCard()

                    VStack(alignment: .leading, spacing: PC.s2) {
                        SectionHeader(text: "Free space, last 30 days")
                        Sparkline(values: [78, 76, 74, 73, 71, 70, 70, 69, 68, 67, 66, 66])
                            .frame(height: 54)
                        Text("Losing about 1 GB a week. At this rate you have roughly 14 weeks of headroom.")
                            .font(.pcSmall).foregroundStyle(PC.ink2)
                    }
                    .padding(PC.gutter).frame(maxWidth: .infinity, alignment: .leading).pcCard()

                    ForEach(findings) { CoachCardView(finding: $0, onQuit: quitAction) }
                }
                .padding(.horizontal, PC.stack).padding(.bottom, PC.stack)
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let lo = values.min() ?? 0, hi = values.max() ?? 1
            let span = max(hi - lo, 0.001)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * Double(i) / Double(max(values.count - 1, 1)),
                        y: g.size.height * (1 - (v - lo) / span))
            }
            ZStack {
                Path { p in p.addLines(pts) }
                    .stroke(PC.accentFill, style: .init(lineWidth: 1.5, lineJoin: .round))
                Path { p in
                    p.addLines(pts)
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                    p.addLine(to: CGPoint(x: 0, y: g.size.height)); p.closeSubpath()
                }
                .fill(LinearGradient(colors: [PC.accentFill.opacity(0.18), .clear],
                                     startPoint: .top, endPoint: .bottom))
            }
        }
    }
}
