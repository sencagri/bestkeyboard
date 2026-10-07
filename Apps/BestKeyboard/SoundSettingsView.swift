import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

struct SoundSettingsView: View {
    let model: KeyboardSettingsModel
    @State private var typed = ""
    @State private var pressed: Int?

    var body: some View {
        let s = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SharedStoreNotice()
                BKCard {
                    Text("Dene: harflere ve boşluğa bas").font(.subheadline).foregroundStyle(BK.sub)
                    HStack(spacing: 6) {
                        ForEach(Array(["k", "a", "l", "e", "m", " "].enumerated()), id: \.offset) { i, ch in
                            Button {
                                let word = ch == " "
                                if s.soundEnabled { KeySoundPlayer.shared.play(word ? s.wordSound : s.letterSound) }
                                typed = String((typed + ch).suffix(28))
                                pressed = i
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { if pressed == i { pressed = nil } }
                            } label: {
                                Text(ch == " " ? "boşluk" : ch)
                                    .font(ch == " " ? .subheadline : .title3)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .foregroundStyle(pressed == i ? .white : BK.ink)
                                    .background(pressed == i ? BK.accent : BK.line, in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: ch == " " ? .infinity : 48)
                        }
                    }
                    (Text(typed) + Text("|").foregroundColor(BK.accent)).font(.body)
                }
                Toggle(isOn: model.binding(\.soundEnabled)) { Text("Basışta ses").font(.body.weight(.semibold)) }
                    .tint(BK.blue.ink)
                    .padding(16).background(BK.card, in: RoundedRectangle(cornerRadius: BK.Radius.card, style: .continuous))
                channelCard("Harf yazarken", "Her harf ve rakamda", BK.accent, BK.purple.chip, \.letterSound)
                channelCard("Kelime bitirirken", "Boşluk, nokta, enter", BK.orange.ink, BK.orange.chip, \.wordSound)
                BKCard {
                    Toggle(isOn: model.binding(\.haptics)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Basışta titreşim").font(.body.weight(.semibold))
                            Text("Parmak tuşa değdiği an").font(.footnote).foregroundStyle(BK.sub)
                        }
                    }.tint(BK.purple.ink)
                    Picker("Titreşim gücü", selection: model.binding(\.hapticLevel)) {
                        ForEach(HapticLevel.labels.indices, id: \.self) { Text(HapticLevel.labels[$0]).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: s.hapticLevel) { _, lv in
                        UIImpactFeedbackGenerator(style: HapticLevel.style(lv)).impactOccurred()
                    }
                }
                Text("Sesler telefonun sessiz moduna uyar. Klavyede ses ve titreşim için Tam Erişim açık olmalı.")
                    .font(.footnote).foregroundStyle(BK.sub).padding(.horizontal, 4)
            }
            .padding(16)
        }
        .foregroundStyle(BK.ink)
        .bkScreen("Ses ve titreşim")
    }

    private func channelCard(_ title: String, _ sub: String, _ ink: Color, _ chip: Color,
                             _ path: WritableKeyPath<KeyboardSettings, KeySoundChannel>) -> some View {
        let ch = model.settings[keyPath: path]
        return BKCard {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(ink)
                Text(sub).font(.footnote).foregroundStyle(BK.sub)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(KeySoundKind.allCases, id: \.self) { kind in
                    let on = ch.kind == kind
                    Button {
                        model.update { $0[keyPath: path].kind = kind }
                        KeySoundPlayer.shared.play(model.settings[keyPath: path])
                    } label: {
                        Text(kind.title).font(.subheadline.weight(on ? .bold : .medium))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(on ? ink : BK.ink)
                            .background(on ? chip : BK.ground, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? ink : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            BKSliderRow(SettingsSliders.volume("Şiddet"), tint: ink,
                        x: Binding(get: { model.settings[keyPath: path].volume },
                                   set: { v in model.update { $0[keyPath: path].volume = v } }))
                .onChange(of: ch.volume) { _, _ in KeySoundPlayer.shared.play(model.settings[keyPath: path]) }
        }
    }
}
