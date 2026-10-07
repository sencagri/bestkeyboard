import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct BestKeyboardWidgets: WidgetBundle {
    var body: some Widget {
        DictationLiveActivity()
        if #available(iOS 18.0, *) {
            ScreenshotReminderControl()
            ScreenshotEventControl()
            DictationControl()
        }
    }
}

/// Tasarım tuvali "19 · Sesle yazma adası": kompakt (dalga + sayaç),
/// açık (durum, son kelimeler, Duraklat / Bitti — yaz), kilit ekranı.
struct DictationLiveActivity: Widget {
    static let accent = Color(red: 0x5B / 255, green: 0x4F / 255, blue: 0xF0 / 255)
    static let soft = Color(red: 0x8F / 255, green: 0x84 / 255, blue: 0xFF / 255)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationAttributes.self) { ctx in
            LockScreenView(state: ctx.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill").font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white).frame(width: 30, height: 30)
                            .background(s.listening ? Self.accent : Color.gray, in: Circle())
                        Text(s.done ? "Klavyeye yazıldı" : s.listening ? "Dinliyor" : "Duraklatıldı")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerText(state: s).font(.system(size: 15, weight: .semibold)).foregroundStyle(Self.soft)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(s.tail.isEmpty ? "Konuşmaya başla…" : s.tail)
                            .font(.system(size: 16)).foregroundStyle(.white.opacity(0.9))
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        if !s.done {
                            HStack(spacing: 10) {
                                Button(intent: ToggleDictationIntent()) {
                                    Text(s.listening ? "Duraklat" : "Devam").font(.system(size: 15, weight: .bold))
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                }
                                .tint(Color.white.opacity(0.18))
                                Button(intent: FinishDictationIntent()) {
                                    Text("Bitti — yaz").font(.system(size: 15, weight: .bold))
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                }
                                .tint(Self.accent)
                                .layoutPriority(1)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Waveform(active: s.listening).padding(.leading, 2)
            } compactTrailing: {
                TimerText(state: s).font(.system(size: 14, weight: .semibold)).foregroundStyle(Self.soft)
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: s.done ? "checkmark" : "mic.fill").foregroundStyle(Self.soft)
            }
            .keylineTint(Self.accent)
        }
    }
}

/// Dinlerken sistem sayıyor (güncelleme gerekmiyor); duraklatılınca sabit.
private struct TimerText: View {
    let state: DictationAttributes.ContentState
    var body: some View {
        if state.listening && !state.done {
            Text(timerInterval: state.runStart...Date.distantFuture, countsDown: false)
                .monospacedDigit().multilineTextAlignment(.trailing)
        } else {
            Text(Duration.seconds(state.elapsed).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
        }
    }
}

/// Canlı Etkinlikte animasyon yok; dört çubuk, dinlerken dolu, değilse sönük.
private struct Waveform: View {
    let active: Bool
    var body: some View {
        HStack(spacing: 2) {
            ForEach([0.45, 0.9, 0.6, 1.0], id: \.self) { h in
                Capsule().fill(DictationLiveActivity.soft.opacity(active ? 1 : 0.4))
                    .frame(width: 3, height: 14 * h)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: DictationAttributes.ContentState
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(DictationLiveActivity.accent, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(state.done ? "Klavyeye yazıldı" : "Sesle yazma ·")
                    if !state.done { TimerText(state: state) }
                }
                .font(.system(size: 15, weight: .bold))
                Text(state.tail.isEmpty ? "Konuşmaya başla…" : state.tail)
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !state.done {
                Button(intent: FinishDictationIntent()) {
                    Text("Bitti").font(.system(size: 14, weight: .bold)).padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .tint(DictationLiveActivity.accent)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
    }
}
