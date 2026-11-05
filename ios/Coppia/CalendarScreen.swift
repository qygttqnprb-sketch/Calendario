import SwiftUI
import Supabase
struct CalendarScreen: View {
    @EnvironmentObject var store: AppStore
    @State private var mode = "Mese"
    @State private var filter = "Tutti"
    @State private var editing = false
    @State private var editEvent: CalendarEvent?
    var calendar: Calendar { CoupleClock.calendar(store.timezone) }
    var interval: DateInterval { calendar.dateInterval(of:mode == "Mese" ? .month : mode == "Settimana" ? .weekOfYear : .day,for:store.selectedDate)! }
    var filtered: [CalendarEvent] {
        store.events.filter {
            $0.start < interval.end && $0.end > interval.start &&
            (filter == "Tutti" || (filter == "Miei" ? $0.owner_id == store.userID : $0.visibility == "shared"))
        }.sorted { $0.start < $1.start }
    }
    var days: [Date] {
        let month = calendar.dateInterval(of:.month,for:store.selectedDate)!
        let start = CoupleClock.weekStart(month.start,zone:store.timezone)
        return (0..<42).compactMap { calendar.date(byAdding:.day,value:$0,to:start) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Vista",selection:$mode) { ForEach(["Mese","Settimana","Giorno"],id:\.self) { Text($0) } }.pickerStyle(.segmented)
                    HStack {
                        Button { move(-1) } label: { Image(systemName:"chevron.left") }.accessibilityLabel("Periodo precedente")
                        Spacer(); Text(display(store.selectedDate, format:"MMMM yyyy")).font(.headline); Spacer()
                        Button { move(1) } label: { Image(systemName:"chevron.right") }.accessibilityLabel("Periodo successivo")
                    }.buttonStyle(.borderless)
                    if mode == "Mese" {
                        LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:7),spacing:12) {
                            ForEach(["L","M","M","G","V","S","D"].indices,id:\.self) { i in Text(["L","M","M","G","V","S","D"][i]).font(.caption).foregroundStyle(.secondary) }
                            ForEach(days,id:\.self) { day in
                                Button { store.selectedDate=day; mode="Giorno" } label: {
                                    VStack(spacing:3) {
                                        Text("\(calendar.component(.day,from:day))").fontWeight(calendar.isDate(day,inSameDayAs:store.selectedDate) ? .bold : .regular)
                                        Circle().fill(store.events.contains { calendar.isDate($0.start,inSameDayAs:day) } ? Color.indigo : .clear).frame(width:4,height:4)
                                    }.frame(maxWidth:.infinity).foregroundStyle(calendar.isDate(day,equalTo:store.selectedDate,toGranularity:.month) ? Color.primary : Color.secondary)
                                }.buttonStyle(.borderless)
                            }
                        }
                    } else { DatePicker("Data",selection:$store.selectedDate,displayedComponents:.date) }
                    Picker("Mostra",selection:$filter) { ForEach(["Tutti","Miei","Condivisi"],id:\.self) { Text($0) } }
                }
                Section("In programma") {
                    if filtered.isEmpty { ContentUnavailableView("Tempo libero",systemImage:"sun.max",description:Text("Aggiungi il prossimo momento per voi.")) }
                    ForEach(filtered) { event in
                        VStack(alignment:.leading,spacing:6) {
                            HStack { Text(event.title).font(.headline); Spacer(); if event.visibility == "private" { Image(systemName:"lock") } }
                            Text(display(event.start, format:"EEE d MMM, HH:mm")).font(.subheadline).foregroundStyle(.secondary)
                            if !event.description.isEmpty { Text(event.description) }
                            if !event.location_text.isEmpty { Label(event.location_text,systemImage:"mappin") }
                            if let raw=event.external_url, let url=CoupleClock.safeURL(raw) { Link("Apri link",destination:url) }
                            if event.owner_id == store.userID { Button("Modifica") { editEvent=event; editing=true }.buttonStyle(.borderless) }
                        }.padding(.vertical,5)
                    }
                }
            }.navigationTitle("Il vostro tempo")
                .toolbar { Button { editEvent=nil; editing=true } label: { Image(systemName:"plus") }.accessibilityLabel("Nuovo evento") }
                .sheet(isPresented:$editing) { EventEditor(event:editEvent) }
                .refreshable { await store.refresh() }
                .onChange(of:store.selectedDate) { _,_ in Task { await store.refresh() } }
                .environment(\.timeZone,calendar.timeZone)
        }
    }
    func display(_ date: Date, format: String) -> String { let f=DateFormatter(); f.locale=Locale(identifier:"it_IT"); f.timeZone=calendar.timeZone; f.dateFormat=format; return f.string(from:date) }
    func move(_ n: Int) { store.selectedDate=calendar.date(byAdding:mode == "Mese" ? .month : mode == "Settimana" ? .weekOfYear : .day,value:n,to:store.selectedDate)! }
}
struct EventEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let event: CalendarEvent?
    @State private var title = ""
    @State private var description = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var visibility = "shared"
    @State private var partner = false
    @State private var location = ""
    @State private var link = ""
    @State private var loaded = false
    @State private var participantsLoading = false
    var valid: Bool { !title.trimmingCharacters(in:.whitespaces).isEmpty && end>start && (link.isEmpty || CoupleClock.safeURL(link) != nil) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Attività") { TextField("Titolo",text:$title); TextField("Descrizione",text:$description,axis:.vertical) }
                Section("Quando · \(store.timezone)") {
                    DatePicker("Inizio",selection:$start); DatePicker("Fine",selection:$end,in:start...)
                }
                Section("Con chi e cosa condividere") {
                    Picker("Privacy",selection:$visibility) { Text("Condiviso").tag("shared"); Text("Privato").tag("private"); Text("Solo occupato").tag("busy_only") }
                    Toggle("Partecipa anche il partner",isOn:$partner).disabled(visibility != "shared" || store.people.count<2)
                    Text(visibility == "private" ? "Visibile soltanto a te." : visibility == "busy_only" ? "Il partner vedrà soltanto l’intervallo occupato." : "Dettagli visibili a entrambi.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Luogo e link") {
                    TextField("Luogo",text:$location)
                    TextField("https://…",text:$link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Puoi collegare TheFork, Too Good To Go e mappe con URL HTTPS. Le prenotazioni si completano sul servizio esterno.").font(.caption).foregroundStyle(.secondary)
                }
                if !valid { Text("Inserisci un titolo, una fine successiva all’inizio e un link HTTPS valido, se presente.").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle(event == nil ? "Nuovo momento" : "Modifica evento")
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Annulla") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button("Salva") { Task {
                        guard let c=store.couple else { return }
                        let input=EventInput(p_couple_id:c.id,p_title:title,p_starts_at:start.ISO8601Format(),p_ends_at:end.ISO8601Format(),p_visibility:visibility,p_description:description,p_location:location,p_url:link.isEmpty ? nil : link,p_partner:partner,p_event_id:event?.id)
                        if await store.save(input) { dismiss() }
                    } }.disabled(!valid || store.busy || participantsLoading) }
                }.task {
                    guard !loaded else { return }; loaded=true
                    participantsLoading=true; defer { participantsLoading=false }
                    if let e=event {
                        title=e.title; description=e.description; start=e.start; end=e.end; visibility=e.visibility; location=e.location_text; link=e.external_url ?? ""
                        // Read actual participants; never silently add a partner on edit.
                        if let client=store.client {
                            struct Participant: Decodable { let user_id: UUID }
                            do { let rows: [Participant] = try await client.from("event_participants").select("user_id").eq("event_id",value:e.id).execute().value; partner=rows.count>1 }
                            catch { store.error=error.localizedDescription }
                        }
                    }
                }.environment(\.timeZone,CoupleClock.calendar(store.timezone).timeZone)
        }
    }
}
