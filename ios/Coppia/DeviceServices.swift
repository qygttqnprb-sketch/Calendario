import Foundation
import EventKit
import UserNotifications

@MainActor enum DeviceServices {
    static func weeklyReminder(enabled: Bool, zone: String) async throws {
        let center=UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers:["coppia.weekly"])
        guard enabled else { return }
        guard try await center.requestAuthorization(options:[.alert,.sound,.badge]) else {
            throw NSError(domain:"Coppia",code:1,userInfo:[NSLocalizedDescriptionKey:"Notifiche non autorizzate. Puoi abilitarle nelle impostazioni iOS."])
        }
        let content=UNMutableNotificationContent(); content.title="Una nuova settimana per voi"
        content.body="Scegli i tuoi nuovi impegni e ritrova quelli ancora aperti."
        var date=DateComponents(); date.timeZone=TimeZone(identifier:zone); date.weekday=2; date.hour=9
        try await center.add(UNNotificationRequest(identifier:"coppia.weekly",content:content,trigger:UNCalendarNotificationTrigger(dateMatching:date,repeats:true)))
    }
    // Manual, one-way upsert. Calendar is never read before explicit full-access consent.
    static func export(events:[CalendarEvent], user:UUID) async throws {
        let store=EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw NSError(domain:"Coppia",code:2,userInfo:[NSLocalizedDescriptionKey:"Accesso al calendario non autorizzato."])
        }
        guard let calendar=store.defaultCalendarForNewEvents else {
            throw NSError(domain:"Coppia",code:3,userInfo:[NSLocalizedDescriptionKey:"Nessun calendario Apple scrivibile disponibile."])
        }
        for item in events where item.owner_id == user {
            let key="eventkit.\(user.uuidString).\(item.id.uuidString)"
            let marker=URL(string:"coppia-sync://event/\(user.uuidString)/\(item.id.uuidString)")!
            let saved=UserDefaults.standard.string(forKey:key).flatMap { store.event(withIdentifier:$0) }
            // If iCloud changed an identifier, recover by stable URL within the visible date window.
            let predicate=store.predicateForEvents(withStart:item.start.addingTimeInterval(-86400),end:item.end.addingTimeInterval(86400),calendars:nil)
            let existing=saved ?? store.events(matching:predicate).first { $0.url == marker }
            let event=existing ?? EKEvent(eventStore:store)
            if existing == nil { event.calendar=calendar }
            event.title=item.title; event.notes=item.description; event.startDate=item.start; event.endDate=item.end
            event.timeZone=TimeZone(identifier:item.timezone); event.location=item.location_text; event.url=marker
            try store.save(event,span:.thisEvent,commit:true)
            UserDefaults.standard.set(event.eventIdentifier,forKey:key)
        }
    }
}
