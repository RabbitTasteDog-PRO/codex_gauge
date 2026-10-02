import AppKit
import SwiftUI
import UsageCore

enum GaugeStyle {
    /// Warn when the selected quota has little remaining capacity.
    static func color(for percent: Double?) -> Color {
        guard let percent else { return .secondary }
        if percent <= 5 { return .red }
        if percent <= 20 { return .orange }
        return .accentColor
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + "%"
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "ko_KR")).month().day().hour().minute())
    }

    /// AppKit status items reliably preserve a rendered image in the menu label.
    static func menuImage(percent: Double?, isDark: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 12), flipped: false) { bounds in
            let base = isDark ? NSColor.white : NSColor.black
            let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
            base.withAlphaComponent(0.10).setFill()
            track.fill()
            if let percent {
                let clamped = min(100, max(0, percent.isFinite ? percent : 0))
                let fillColor: NSColor = clamped <= 5 ? .systemRed : (clamped <= 20 ? .systemOrange : .controlAccentColor)
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

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                if let percent {
                    Capsule()
                        .fill(GaugeStyle.color(for: percent))
                        .frame(width: max(0, geometry.size.width * CGFloat(percent / 100)))
                }
                Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.7)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct GaugePanel: View {
    @ObservedObject var store: UsageStore
    @State private var showsSettings = false
    @State private var confirmsLogout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            accountCard
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
            footer
        }
        .padding(18)
        .frame(width: 340)
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
                Text("구독 한도와 토큰 사용량")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(store.errorMessage != nil || store.isStale ? Color.orange : (store.report != nil ? Color.green : Color.secondary))
                    .frame(width: 5, height: 5)
                Text(store.connectionLabel).font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var quotaCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("남은 한도").font(.subheadline.weight(.medium))
                Spacer()
                if store.windows.count > 1 {
                    Picker("표시할 한도", selection: $store.selectedWindowID) {
                        ForEach(store.windows) { window in
                            Text(window.title).tag(window.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("메뉴 막대에 표시할 한도 선택")
                }
            }
            if let window = store.selectedWindow {
                HStack(alignment: .firstTextBaseline) {
                    Text(GaugeStyle.percent(window.quota.remainingPercent))
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(GaugeStyle.color(for: window.quota.remainingPercent))
                    Spacer()
                    Text(window.durationLabel).font(.caption).foregroundStyle(.secondary)
                }
                QuotaGauge(percent: window.quota.remainingPercent, height: 7)
                Text(window.bucketName).font(.caption).foregroundStyle(.secondary)
                if let reset = window.quota.resetDate {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("한도 초기화").font(.caption2).foregroundStyle(.secondary)
                                Text(GaugeStyle.date(reset)).font(.caption)
                            }
                            Spacer()
                            Text(GaugeStyle.remaining(until: reset, now: context.date))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("초기화 시각이 제공되지 않았습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("—").font(.system(size: 36, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                Text(store.isRefreshing ? "Codex 사용량을 조회하고 있습니다." : "Codex 연결 후 사용 가능한 한도를 표시합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("토큰 사용량").font(.subheadline.weight(.medium))
            if let tokens = store.report?.tokens {
                if let total = tokens.summary?.lifetimeTokens {
                    metric("계정 누적", value: total.formatted())
                }
                if let latest = tokens.latestBucket {
                    metric("최근 일별 기록", value: latest.tokens.formatted())
                    Text("서비스 기준 날짜 · \(latest.startDate)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .textSelection(.enabled)
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
            Text("구독 한도 비율과 토큰 수는 서로 다른 지표입니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    private func metric(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
                .textSelection(.enabled)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 5) {
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                    Text("갱신 중")
                } else if let lastUpdated = store.lastUpdated {
                    Text("마지막 갱신 · \(GaugeStyle.date(lastUpdated))")
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
