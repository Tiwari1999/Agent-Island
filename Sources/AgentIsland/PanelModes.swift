import SwiftUI

/// What the panel's list area is showing: the sessions, the money, or one session's plan.
enum PanelMode: Equatable {
    case sessions, costs, plan(session: String, title: String)
}

/// Markdown rendered line-by-line — SwiftUI's AttributedString parser flattens block structure,
/// which makes a plan read as one grey paragraph. No tables or nesting, deliberately.
struct MarkdownLite: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, b in
                block(b)
            }
        }
    }

    enum Block: Equatable {
        case heading(Int, String), bullet(String), code(String), rule, plain(String)
    }

    static func blocks(_ raw: String) -> [Block] {
        var out: [Block] = []
        var fence: [String] = []
        var inFence = false
        for lineSub in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inFence { out.append(.code(fence.joined(separator: "\n"))); fence = [] }
                inFence.toggle()
                continue
            }
            if inFence { fence.append(line); continue }
            if t.isEmpty { continue }
            if t.hasPrefix("#") {
                let level = t.prefix(while: { $0 == "#" }).count
                out.append(.heading(min(level, 3),
                                    t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if t == "---" || t == "***" {
                out.append(.rule)
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
                out.append(.bullet(String(t.dropFirst(2))))
            } else {
                out.append(.plain(t))
            }
        }
        if inFence, !fence.isEmpty { out.append(.code(fence.joined(separator: "\n"))) }
        return out
    }

    @ViewBuilder private func block(_ b: Block) -> some View {
        switch b {
        case .heading(let level, let s):
            inline(s)
                .font(Theme.label(level == 1 ? 13 : level == 2 ? 12 : 11))
                .foregroundColor(Theme.text)
                .padding(.top, 4)
        case .bullet(let s):
            HStack(alignment: .top, spacing: 6) {
                Text("•").font(Theme.mono(10)).foregroundColor(Theme.faint)
                inline(s).font(Theme.mono(10.5)).foregroundColor(Theme.muted)
            }
        case .code(let s):
            Text(s)
                .font(Theme.mono(9.5)).foregroundColor(Theme.muted)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 0.7).padding(.vertical, 2)
        case .plain(let s):
            inline(s).font(Theme.mono(10.5)).foregroundColor(Theme.muted)
        }
    }

    private func inline(_ s: String) -> Text {
        // Bold and code spans come through AttributedString; anything invalid stays literal.
        if let a = try? AttributedString(markdown: s) { return Text(a) }
        return Text(s)
    }
}

/// One session's plan, readable without leaving the notch.
struct PlanReader: View {
    let title: String
    let markdown: String
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("‹ sessions")
                    .font(Theme.label(10.5)).foregroundColor(Theme.working)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onBack)
                Text(title).font(Theme.label(11)).foregroundColor(Theme.text).lineLimit(1)
                Spacer()
                Text("plan").font(Theme.mono(9)).foregroundColor(Theme.faint)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Rectangle().fill(Theme.hairline).frame(height: 0.7)
            ScrollView {
                MarkdownLite(text: markdown)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The month's spend at API list prices, by model.
struct CostsView: View {
    let table: Costs.Table
    let onBack: () -> Void

    var body: some View {
        let today = Costs.today(table)
        let month = Costs.monthTotal(table)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("‹ sessions")
                    .font(Theme.label(10.5)).foregroundColor(Theme.working)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onBack)
                Text("Usage cost").font(Theme.label(11)).foregroundColor(Theme.text)
                Spacer()
                // Honesty over drama: nobody on a subscription is billed these numbers.
                Text("API-equivalent — subscription usage isn't billed per token")
                    .font(Theme.mono(8.5)).foregroundColor(Theme.faint)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Rectangle().fill(Theme.hairline).frame(height: 0.7)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("TODAY", today)
                    section("THIS MONTH", month)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder private func section(_ name: String, _ models: [String: Costs.Line]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(Theme.mono(9)).foregroundColor(Theme.faint).kerning(0.8)
                Spacer()
                Text(Costs.dollars(models.values.reduce(0) { $0 + $1.cost }))
                    .font(Theme.label(12)).foregroundColor(Theme.text)
            }
            if models.isEmpty {
                Text("no usage recorded").font(Theme.mono(9.5)).foregroundColor(Theme.faint)
            }
            ForEach(models.sorted { $0.value.cost > $1.value.cost }, id: \.key) { model, l in
                HStack(spacing: 10) {
                    Text(model).font(Theme.mono(10)).foregroundColor(Theme.muted)
                        .frame(width: 150, alignment: .leading).lineLimit(1)
                    cell("in", l.input)
                    cell("out", l.output)
                    cell("cache", l.cacheRead + l.cacheWrite)
                    Spacer()
                    Text(Costs.dollars(l.cost))
                        .font(Theme.mono(10.5)).foregroundColor(Theme.text)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func cell(_ label: String, _ n: Int) -> some View {
        HStack(spacing: 3) {
            Text(label).font(Theme.mono(8.5)).foregroundColor(Theme.faint)
            Text(Costs.tokens(n)).font(Theme.mono(9.5)).foregroundColor(Theme.muted)
        }
        .frame(width: 86, alignment: .leading)
    }
}
