import SwiftUI
import Supabase
import UserNotifications

@MainActor final class AppStore: ObservableObject {
    @Published var userID: UUID?
    @Published var couple: Couple?
    @Published var people: [Profile] = []
    @Published var events: [CalendarEvent] = []
    @Published var obligations: [Obligation] = []
    @Published var requests: [CompletionRequest] = []
    @Published var quota = 2
    @Published var selectedDate = Date()
    @Published var week = ""
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false
    @Published var ready = false
    @Published var inviteCode: String?
    let client: SupabaseClient?
    private var realtimeTask: Task<Void, Never>?
    private var channel: RealtimeChannelV2?
    private var refreshing = false

    init() {
        let url = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String ?? ""
        if let u = URL(string: url), u.scheme == "https", key.hasPrefix("sb_publishable_"), !url.contains("YOUR_PROJECT") {
            client = SupabaseClient(supabaseURL: u, supabaseKey: key)
        } else { client = nil }
    }
    var timezone: String { couple?.timezone ?? "Europe/Rome" }
    var mine: [Obligation] { obligations.filter { $0.owner_id == userID } }
    var incoming: [CompletionRequest] { requests.filter { $0.reviewer_id == userID && $0.status == "pending" } }
    func person(_ id: UUID) -> String { people.first { $0.id == id }?.display_name ?? "Partner" }
    func title(_ slot: Obligation) -> String { events.first { $0.id == slot.event_id }?.title ?? (slot.event_id == nil ? "Scegli un’attività" : "Attività riservata") }

    func start() async {
        guard let client else { ready = true; return }
        for await (_, session) in client.auth.authStateChanges {
            let next = session?.user.id
            if userID != next {
                userID = next
                await stopRealtime()
                couple = nil; events = []; obligations = []; requests = []; people = []; inviteCode = nil
            }
            if next != nil { await refresh(); await listen() }
            ready = true
        }
    }
    func run(_ operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await operation() } catch { self.error = error.localizedDescription }
    }
    func authenticate(email: String, password: String, signup: Bool) async {
        guard let client else { return }
        await run {
            if signup {
                let result = try await client.auth.signUp(email: email, password: password)
                if result.session == nil { self.notice = "Controlla la tua email per confermare l’account, poi accedi." }
            } else { _ = try await client.auth.signIn(email: email, password: password) }
        }
    }
    func onboard(name: String, coupleName: String, code: String) async {
        guard let client else { return }
        await run {
            if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try await client.rpc("create_couple", params: ["p_name":coupleName,"p_display_name":name]).execute()
            } else {
                _ = try await client.rpc("join_couple", params: ["p_code":code,"p_display_name":name]).execute()
            }
            await self.refresh(); await self.listen()
        }
    }
    func refresh() async {
        guard let client, let userID, !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let memberships: [Membership] = try await client.from("couple_members").select().eq("user_id", value: userID).execute().value
            guard let membership = memberships.first else { return }
            let couples: [Couple] = try await client.from("couples").select().eq("id", value: membership.couple_id).execute().value
            guard let c = couples.first else { return }; couple = c
            week = try await client.rpc("ensure_weekly_slots", params: ["p_couple_id":c.id.uuidString]).execute().value
            let settings: [Settings] = try await client.from("couple_settings").select().eq("couple_id", value:c.id).execute().value
            quota = settings.first?.weekly_quota_per_person ?? 2
            people = try await client.from("profiles").select().execute().value
            var allSlots: [Obligation] = []
            var offset = 0
            while true {
                let page: [Obligation] = try await client.from("obligation_slots").select().eq("couple_id", value:c.id).lte("origin_week_start", value:week).or("status.neq.completed,origin_week_start.eq.\(week)").order("origin_week_start").order("id").range(from:offset,to:offset+499).execute().value
                allSlots += page
                if page.count < 500 { break }; offset += 500
            }
            obligations = allSlots
            requests = try await client.from("completion_requests").select().eq("status", value:"pending").execute().value
            let cal = CoupleClock.calendar(c.timezone)
            let interval = cal.dateInterval(of: .month, for: selectedDate)!
            let from = cal.date(byAdding: .day, value: -7, to: interval.start)!
            let to = cal.date(byAdding: .day, value: 7, to: interval.end)!
            events = try await client.rpc("calendar_events", params: ["p_couple_id":c.id.uuidString,"p_from":from.ISO8601Format(),"p_to":to.ISO8601Format()]).execute().value
            let ids = obligations.compactMap(\.event_id).map(\.uuidString)
            if !ids.isEmpty {
                let associated: [CalendarEvent] = try await client.from("events").select().in("id", values: ids).execute().value
                events += associated.filter { e in !events.contains { $0.id == e.id } }
            }
        } catch { self.error = error.localizedDescription }
    }
    func listen() async {
        guard let client, let couple, channel == nil else { return }
        let ch = await client.channel("couple-\(couple.id)")
        let changes = await ch.postgresChange(AnyAction.self, schema:"public", table:"couple_changes", filter:.eq("couple_id", value:couple.id.uuidString))
        do { try await ch.subscribeWithError() } catch { self.error = "Aggiornamento live non disponibile: \(error.localizedDescription)"; return }
        channel = ch
        realtimeTask = Task { [weak self] in for await _ in changes { guard !Task.isCancelled else { break }; await self?.refresh() } }
        await refresh() // Close the fetch/subscribe race.
    }
    func stopRealtime() async {
        realtimeTask?.cancel(); realtimeTask = nil
        if let channel, let client { await client.removeChannel(channel) }; channel = nil
    }
    func save(_ input: EventInput) async -> Bool {
        guard let client else { return false }; var success = false
        await run { _ = try await client.rpc("save_event", params: input).execute(); success = true; await self.refresh() }
        return success
    }
    func assign(_ slot: Obligation, event: UUID, kind: String) async {
        guard let client else { return }
        await run { _ = try await client.rpc("assign_obligation", params:["p_obligation_id":slot.id.uuidString,"p_event_id":event.uuidString,"p_kind":kind]).execute(); await self.refresh() }
    }
    func request(_ slot: Obligation, note: String) async {
        guard let client else { return }
        await run { _ = try await client.rpc("request_completion", params:["p_obligation_id":slot.id.uuidString,"p_note":note]).execute(); await self.refresh() }
    }
    func review(_ request: CompletionRequest, approve: Bool, note: String) async {
        struct Input: Encodable { let p_request_id: UUID; let p_approve: Bool; let p_note: String }
        guard let client else { return }
        await run { _ = try await client.rpc("review_completion", params:Input(p_request_id:request.id,p_approve:approve,p_note:note)).execute(); await self.refresh() }
    }
    func invite() async {
        guard let client, let couple else { return }
        await run { self.inviteCode = try await client.rpc("create_invite", params:["p_couple_id":couple.id.uuidString]).execute().value }
    }
    func settings(zone: String, quota: Int) async {
        struct Input: Encodable { let p_couple_id: UUID; let p_timezone: String; let p_quota: Int }
        guard let client, let couple else { return }
        await run { _ = try await client.rpc("update_settings", params:Input(p_couple_id:couple.id,p_timezone:zone,p_quota:quota)).execute(); await self.refresh() }
    }
    func logout() async {
        guard let client else { return }
        await run { try await client.auth.signOut(); await self.stopRealtime() }
    }
}
