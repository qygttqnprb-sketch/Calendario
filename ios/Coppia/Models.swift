import Foundation

struct Couple: Codable, Identifiable { let id: UUID; let name: String; let timezone: String }
struct Membership: Decodable { let couple_id: UUID; let user_id: UUID }
struct Profile: Decodable, Identifiable { let id: UUID; let display_name: String }
struct Settings: Decodable { let weekly_quota_per_person: Int }
struct CalendarEvent: Codable, Identifiable {
    let id: UUID
    let owner_id: UUID
    let title: String
    let description: String
    let starts_at: String
    let ends_at: String
    let timezone: String
    let visibility: String
    let location_text: String
    let external_url: String?
    var start: Date { Self.parse(starts_at) }
    var end: Date { Self.parse(ends_at) }
    static func parse(_ value: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value) ?? ISO8601DateFormatter().date(from: value) ?? .distantPast
    }
}
struct Obligation: Decodable, Identifiable {
    let id: UUID; let owner_id: UUID; let origin_week_start: String
    let slot_index: Int; let event_id: UUID?; let kind: String?; let status: String
    var statusLabel: String {
        ["empty":"Da scegliere", "scheduled":"In programma", "pending_confirmation":"In attesa del partner", "completed":"Confermato", "disputed":"Da ripresentare"][status] ?? status
    }
}
struct CompletionRequest: Decodable, Identifiable {
    let id: UUID; let obligation_id: UUID; let reviewer_id: UUID
    let requested_by: UUID; let status: String; let note: String
}
struct EventInput: Encodable {
    let p_couple_id: UUID; let p_title: String; let p_starts_at: String; let p_ends_at: String
    let p_visibility: String; let p_description: String; let p_location: String
    let p_url: String?; let p_partner: Bool; let p_event_id: UUID?
}
enum CoupleClock {
    static func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: zone) ?? TimeZone(identifier: "Europe/Rome")!
        return c
    }
    static func weekStart(_ date: Date, zone: String) -> Date {
        calendar(zone).dateInterval(of: .weekOfYear, for: date)!.start
    }
    static func dayKey(_ date: Date, zone: String) -> String {
        let f = DateFormatter(); f.calendar = calendar(zone); f.timeZone = f.calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
    static func safeURL(_ string: String) -> URL? {
        guard let u = URL(string: string), u.scheme == "https", let host = u.host,
              host.contains("."), u.user == nil, u.password == nil, u.port == nil,
              !string.contains("\\"), !string.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return u
    }
}
