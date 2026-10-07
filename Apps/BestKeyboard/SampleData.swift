import Foundation

/// Örnek veri — tuş düzenleyicisindeki örnek mesajlar, tasarım karşılaştırma
/// ekranları ve öz-testler aynı buluşmayı ve aynı kişiyi kullanıyor.
enum SampleData {
    static let meetingMessage = "Cumartesi akşam 7'de Kadıköy'de buluşalım, 2 saat kadar otururuz"
    static let contactMessage = "Tesisatçının numarası: Murat Kaya 0532 418 77 90, mail murat@kayatesisat.com"
    static let reminderMessage = "Cumartesi annen gelecek, akşam otogardan alacaksın. 8 yumurta, 5 kedi maması al."

    /// Gelecek cumartesi 19:00.
    static var saturdayEvening: Date {
        Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 19, minute: 0, weekday: 7),
                                  matchingPolicy: .nextTime) ?? Date()
    }

    static var meeting: AIService.EventDraft {
        let start = saturdayEvening
        return .init(title: "Kadıköy'de buluşma", start: start, end: start.addingTimeInterval(7200),
                     allDay: false, location: "Kadıköy", notes: nil)
    }

    static let contact = AIService.ContactDraft(givenName: "Murat", familyName: "Kaya", phones: ["0532 418 77 90"],
                                                emails: ["murat@kayatesisat.com"], organization: "Kaya Tesisat", note: nil)
}

#if DEBUG
extension EventHandoff {
    /// `-bkScreen yzetkinlik`: tasarım 32a'daki örnek.
    static var sample: EventHandoff { EventHandoff(plan: .init(calendar: nil, items: [SampleData.meeting]), edit: true) }
}

extension ContactHandoff {
    /// `-bkScreen yzkisi`: tasarım 32b'deki örnek.
    static var sample: ContactHandoff { ContactHandoff(draft: SampleData.contact, edit: true) }
}
#endif
