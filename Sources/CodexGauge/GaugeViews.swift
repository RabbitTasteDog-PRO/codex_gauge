import AppKit
import SwiftUI
import UsageCore

enum GaugeStyle {
    /// Shown in the panel so the running build is never ambiguous.
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    /// Warn when the selected quota has little remaining capacity.
    static func color(for percent: Double?, celebratingReset: Bool = false) -> Color {
        guard let percent else { return .secondary }
        if celebratingReset && percent == 100 { return .green }
        if percent <= 5 { return .red }
        if percent <= 20 { return .orange }
        return .blue
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + "%"
    }

    static func compactTokens(_ value: Int64) -> String {
        let unit: (divisor: Double, suffix: String)
        if value >= 100_000_000 { unit = (100_000_000, "억") }
        else if value >= 10_000 { unit = (10_000, "만") }
        else { return value.formatted() }
        return (Double(value) / unit.divisor).formatted(.number.precision(.fractionLength(0...1))) + unit.suffix
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "ko_KR")).month().day().hour().minute())
    }

    /// AppKit status items reliably preserve a rendered image in the menu label.
    static func menuImage(percent: Double?, isDark: Bool, celebratingReset: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 12), flipped: false) { bounds in
            let base = isDark ? NSColor.white : NSColor.black
            let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
            base.withAlphaComponent(0.10).setFill()
            track.fill()
            if let percent {
                let clamped = min(100, max(0, percent.isFinite ? percent : 0))
                let fillColor: NSColor = celebratingReset && clamped == 100 ? .systemGreen
                    : (clamped <= 5 ? .systemRed : (clamped <= 20 ? .systemOrange : .systemBlue))
                NSGraphicsContext.saveGraphicsState()
                track.addClip()
                fillColor.setFill()
                NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width * clamped / 100, height: bounds.height)).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            base.withAlphaComponent(0.40).setStroke()
            track.lineWidth = 0.7
            track.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A reset deadline is informational; passing it does not locally reset usage.
    static func remaining(until date: Date, now: Date) -> String {
        let minutes = Int(ceil(date.timeIntervalSince(now) / 60))
        if minutes <= 0 { return "초기화 시각 경과" }
        if minutes >= 1440 { return "\(minutes / 1440)일 \((minutes % 1440) / 60)시간 남음" }
        if minutes >= 60 { return "\(minutes / 60)시간 \(minutes % 60)분 남음" }
        return "\(minutes)분 남음"
    }
}

private struct QuotaGauge: View {
    let percent: Double?
    let height: CGFloat
    var celebratingReset = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                if let percent {
                    Capsule()
                        .fill(GaugeStyle.color(for: percent, celebratingReset: celebratingReset))
                        .frame(width: max(0, geometry.size.width * CGFloat(percent / 100)))
                }
                Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.7)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A compact gauge for every quota; the checked one drives the menu bar gauge.
private struct QuotaRow: View {
    let window: UsageWindow
    var isSelected = false
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.title).font(.caption.weight(isSelected ? .semibold : .regular))
                        Spacer()
                        Text(GaugeStyle.percent(window.quota.remainingPercent))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(GaugeStyle.color(for: window.quota.remainingPercent))
                    }
                    QuotaGauge(percent: window.quota.remainingPercent, height: 5)
                    if let reset = window.quota.resetDate {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            HStack {
                                Text("초기화 · \(GaugeStyle.date(reset))")
                                Spacer()
                                Text(GaugeStyle.remaining(until: reset, now: context.date))
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSelected ? "메뉴 막대에 표시 중" : "체크하면 이 한도를 메뉴 막대에 표시")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.title), 남은 한도 \(GaugeStyle.percent(window.quota.remainingPercent))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct GaugePanel: View {
    @ObservedObject var store: UsageStore
    /// AppKit supplies the same height to the view and its popover.
    var height: CGFloat = 480
    @State private var showsSettings = false
    @State private var confirmsLogout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                scrollableContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340, height: height)
        .background(Color(nsColor: .windowBackgroundColor))
        .popover(isPresented: $showsSettings, arrowEdge: .trailing) {
            GaugeSettings(store: store)
        }
        .alert("Codex 계정에서 로그아웃할까요?", isPresented: $confirmsLogout) {
            Button("취소", role: .cancel) {}
            Button("로그아웃", role: .destructive) { Task { await store.logout() } }
        } message: {
            Text("로그아웃이 완료되면 저장된 사용량을 지우고 앱을 종료합니다. 기존 Codex 로그인 정보를 공유하므로 CLI·IDE 확장에서도 다시 로그인해야 할 수 있습니다.")
        }
    }

    private var scrollableContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            accountCard
            if store.isCelebratingReset {
                Button { store.acknowledgeQuotaReset() } label: {
                    Label("한도가 다시 찼어요! 눌러서 진정시키기", systemImage: "pawprint.fill")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
            }
            quotaCard
            tokenCard
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if store.isStale, store.lastUpdated != nil {
                Label("마지막 조회 값입니다. 새로고침해 주세요.", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: "person.crop.circle").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.account?.email ?? (store.account != nil ? "Codex 계정" : (store.hasCheckedAccount ? "로그인이 필요합니다" : "계정 확인 중")))
                        .font(.caption.weight(.medium)).textSelection(.enabled)
                    Text(store.account.map { $0.planType.map { "ChatGPT · \($0.capitalized)" } ?? $0.type } ?? "ChatGPT 계정으로 사용량 연결")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if !store.isLoggingIn {
                    if store.account != nil {
                        Button("로그아웃") { confirmsLogout = true }
                            .disabled(store.isAuthenticating)
                    } else {
                        Button("로그인") { store.login { NSWorkspace.shared.open($0) } }
                            .disabled(store.isAuthenticating)
                    }
                }
            }
            .buttonStyle(.borderless).font(.caption)
            if store.isLoggingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.isCancellingLogin ? "로그인 취소 중…" : "브라우저에서 로그인을 완료하세요.")
                        .font(.caption)
                    Spacer(minLength: 0)
                    Button("취소") { Task { await store.cancelLogin() } }
                        .disabled(store.isCancellingLogin)
                }
                if let url = store.loginURL {
                    Button("로그인 페이지 다시 열기") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link).font(.caption)
                        .disabled(store.isCancellingLogin)
                }
            }
            if let error = store.authError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Gauge").font(.headline)
                Text("구독 한도와 토큰 사용량 · v\(GaugeStyle.appVersion)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(store.errorMessage != nil || store.isStale ? Color.orange : (store.report != nil ? Color.green : Color.secondary))
                    .frame(width: 5, height: 5)
                Text("Codex · \(store.connectionLabel)").font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var quotaCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let window = store.selectedWindow {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("남은 한도").font(.caption.weight(.medium))
                        Text(window.title).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(GaugeStyle.percent(window.quota.remainingPercent))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(GaugeStyle.color(for: window.quota.remainingPercent, celebratingReset: store.isCelebratingReset))
                }
                QuotaGauge(percent: window.quota.remainingPercent, height: 5, celebratingReset: store.isCelebratingReset)
            } else {
                Text("남은 한도").font(.caption.weight(.medium))
                Text("—").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                Text(store.claudeError != nil && store.selectedWindowID.hasPrefix("claude") ? "Claude 한도를 확인할 수 없습니다." : (store.isRefreshing ? "Codex 사용량을 조회하고 있습니다." : "사용 가능한 한도를 기다리고 있습니다."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !store.windows.isEmpty {
                Divider()
                Text("메뉴 막대에 표시할 한도").font(.caption2).foregroundStyle(.secondary)
                ForEach(store.windows) { item in
                    QuotaRow(window: item, isSelected: item.id == store.selectedWindowID) { store.selectedWindowID = item.id }
                }
            }
            if let claudeError = store.claudeError {
                Label(claudeError, systemImage: "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("토큰 사용량").font(.caption.weight(.medium))
                Spacer()
                if let latest = store.report?.tokens?.latestBucket {
                    Text(latest.startDate).font(.caption2).foregroundStyle(.secondary)
                        .help("최근 일별 기록의 서비스 기준 날짜")
                }
            }
            if let tokens = store.report?.tokens {
                HStack(spacing: 16) {
                    if let total = tokens.summary?.lifetimeTokens {
                        tokenMetric("누적", value: total)
                    }
                    if let latest = tokens.latestBucket {
                        tokenMetric("최근 일별", value: latest.tokens)
                    }
                }
                if tokens.summary?.lifetimeTokens == nil, tokens.latestBucket == nil {
                    Text("표시할 토큰 기록이 없습니다.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("제공되지 않음").font(.caption).foregroundStyle(.secondary)
            }
            if let notice = store.report?.tokenNotice {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 2)
        .help("구독 한도 비율과 토큰 수는 서로 다른 지표입니다. 숫자 위에 마우스를 올리면 정확한 토큰 수를 볼 수 있어요.")
    }

    private func tokenMetric(_ label: String, value: Int64) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(GaugeStyle.compactTokens(value)).font(.caption.weight(.medium)).monospacedDigit()
                .textSelection(.enabled)
                .help("\(value.formatted()) 토큰")
                .accessibilityLabel("\(value.formatted()) 토큰")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 5) {
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                    Text("갱신 중")
                } else if let lastUpdated = store.lastUpdated {
                    Text("Codex 갱신 · \(GaugeStyle.date(lastUpdated))")
                } else {
                    Text("아직 조회되지 않았습니다.")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing || store.isAuthenticating)
                .keyboardShortcut("r")
                Spacer()
                Button("설정") { showsSettings.toggle() }
                Button("종료") {
                    store.stop()
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

private struct GaugeSettings: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("설정").font(.headline)
            Text("Codex 실행 파일").font(.subheadline.weight(.medium))
            TextField("자동 탐색 · 또는 실행 파일 절대 경로", text: $store.executablePath)
                .disabled(store.isAuthenticating)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .accessibilityLabel("Codex 실행 파일 경로")
            Text("비워 두면 설치된 Codex를 자동으로 찾습니다. 경로 변경은 다음 조회부터 적용됩니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("메인 패널에서 로그인·로그아웃할 수 있습니다. 기존 Codex CLI·IDE 확장과 로그인 정보를 공유합니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
    }
}
