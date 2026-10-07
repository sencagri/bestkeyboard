import Contacts
import Vision
import EventKit
import SwiftUI
import UIKit

#if DEBUG
/// `-handoffSelfTest`: klavyenin yaptığı gibi planı App Group'a koyup kimlikli adresi açar.
enum HandoffSelfTest {
    @MainActor static func runIfRequested() {
        guard LaunchArgs.has("-handoffSelfTest") else { return }
        let start = Date().addingTimeInterval(2 * 86_400)
        let plan = AIService.EventPlan(calendar: nil, items: [
            .init(title: "Aktarım testi", start: start, end: start.addingTimeInterval(3600), allDay: false, location: nil, notes: nil)])
        guard let json = try? JSONEncoder().encode(plan), let id = Handoff.put(json),
              let url = DeepLink.url(.event, [URLQueryItem(name: DeepLink.Param.id, value: id)]) else { return }
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); _ = await URLOpener.open(url) }
    }
}

/// `-makerSelfTest <etiket>`: örnek etkinlik + kişi ekler; başlık ve soyadında
/// etiket var — UI testi yalnız bu çalıştırmanın kayıtlarını doğrulayıp siliyor.
enum MakerSelfTest {
    static func runIfRequested() {
        guard LaunchArgs.has("-makerSelfTest") else { return }
        let tag = LaunchArgs.value("-makerSelfTest") ?? "x"
        Task { @MainActor in
            let sat = SampleData.saturdayEvening
            do {
                try await EventMaker.add(AIService.EventPlan(calendar: nil, items: [
                    .init(title: "Annemi otogardan al \(tag)", start: sat, end: sat.addingTimeInterval(3600),
                          allDay: false, location: "Kadıköy otogarı", notes: nil)]), notify: false)
                try await ContactMaker.add(AIService.ContactDraft(
                    givenName: "Ahmet", familyName: "Deneme\(tag)", phones: ["0532 000 00 00"], emails: ["ahmet@example.com"],
                    organization: nil, note: nil), notify: false)
                print("MAKER-SELFTEST-DONE")
            } catch {
                print("MAKER-SELFTEST-FAILED", error)
            }
        }
    }
}
#endif
