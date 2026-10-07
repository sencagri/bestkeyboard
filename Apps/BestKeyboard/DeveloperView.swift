import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

struct DeveloperView: View {
    var body: some View {
        BKScreen("Geliştirici") {
            BKCard {
                BKSectionTitle(text: "Deneme", color: BK.accent)
                NavigationLink { HarnessView().navigationTitle("Tezgah").navigationBarTitleDisplayMode(.inline) } label: {
                    row("Klavye tezgahı", "Her tuşta aday ve maliyet dökümü", "terminal", BK.purple)
                }
                BKDivider()
                row("Kanonik vaka", "l s l e m → kalem · işlem açık farkla elenir", "text.alignleft", BK.purple)
            }
            BKCard {
                BKSectionTitle(text: "Yazım kaydı", color: BK.pink.ink)
                NavigationLink { QuickRecordingView() } label: {
                    row("Hızlı kayıt", "Aklındaki cümleyi yaz, sorunu not et", "record.circle", BK.pink)
                }
                BKDivider()
                NavigationLink { RecordingListView() } label: {
                    row("Kayıt oturumları", "Kayıtlar Mac'ten ./Tools/pull-sessions.sh ile çekilir", "list.bullet.rectangle", BK.pink)
                }
            }
            BKCard {
                BKSectionTitle(text: "Yapay zeka", color: BK.blue.ink)
                NavigationLink { AILogView() } label: {
                    row("Yapay zeka günlüğü", "Son istekler: süre, sonuç, hata", "list.bullet.clipboard", BK.blue)
                }
            }
            BKCard {
                BKSectionTitle(text: "Durum", color: BK.teal.ink)
                LabeledContent("Ayarlar", value: KeyboardSettingsStore.isShared ? "klavyeyle ortak" : "yalnız uygulamada")
                LabeledContent("Tanı satırı", value: "klavyede ⚙︎")
            }
        }
    }

    private func row(_ title: String, _ sub: String, _ icon: String, _ tint: BK.Tint) -> some View {
        BKIconRow(icon: icon, tint: tint, title: title, subtitle: sub)
            .frame(minHeight: 52)
    }
}
