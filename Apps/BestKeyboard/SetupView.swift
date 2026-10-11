import SwiftUI
import UIKit
import KBGeometry
import KBRuntime
import UniformTypeIdentifiers

struct SetupView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var stepSize: CGFloat = 32
    @ScaledMetric(relativeTo: .caption) private var pathItemWidth: CGFloat = 80
    var body: some View {
        BKScreen("Kurulum") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dört adımda hazır").font(.title.weight(.heavy))
                Text("Bir kere yapman yeterli.").foregroundStyle(BK.sub)
            }
            .padding(.horizontal, 4)

            BKCard(padding: 16) {
                step(1, BK.accent, "Klavyeler ayarını aç") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: pathItemWidth), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(["Ayarlar", "Genel", "Klavye", "Klavyeler"], id: \.self) { s in
                            Text(s).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(BK.line, in: RoundedRectangle(cornerRadius: BK.Radius.mini))
                        }
                    }
                }
                BKDivider()
                step(2, BK.accent, "BestKeyboard'u ekle") {
                    Text("\"Yeni Klavye Ekle…\" listesinde bul ve dokun.").font(.subheadline).foregroundStyle(BK.sub)
                }
                BKDivider()
                step(3, BK.orange.ink, "Tam Erişim'i aç") {
                    HStack {
                        Text("Tam Erişime İzin Ver").font(.subheadline)
                        Spacer()
                        Capsule().fill(Color.green).frame(width: 44, height: 26)
                            .overlay(Circle().fill(.white).padding(2), alignment: .trailing)
                    }
                    .padding(10)
                    .background(BK.ground, in: RoundedRectangle(cornerRadius: BK.Radius.field))
                }
                BKDivider()
                step(4, BK.accent, "Klavyeyi seç") {
                    Text("Herhangi bir uygulamada klavyenin altındaki küre simgesine basılı tut, BestKeyboard'u seç.")
                        .font(.subheadline).foregroundStyle(BK.sub)
                }
            }

            BKCallout(title: "Tam Erişim neden gerekiyor?", tint: BK.orange) {
                Text("• Basışta ses ve titreşim\n• Kendi fotoğraflı temaların ve uygulamada yaptığın ayarlar\n• Pano geçmişi, GIF ve çıkartmalar")
                Text("Normal yazma ve kelime öğrenme telefonunda çalışır. Yapay zekâ özelliklerini kullanırsan işlenecek metin veya görsel, bağladığın servise gönderilir. Bu özellikler için internet ve servis bağlantısı gerekir.")
            }

            Button {
                URLOpener.launch(URL(string: UIApplication.openSettingsURLString))
            } label: {
                Text("Ayarları aç").font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
        }
    }

    private func step<C: View>(_ n: Int, _ color: Color, _ title: String,
                               @ViewBuilder _ body: () -> C) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        return layout {
            Text("\(n)").font(.headline.weight(.heavy)).foregroundStyle(.white)
                .frame(width: stepSize, height: stepSize).background(color, in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                body()
            }
        }
    }
}
