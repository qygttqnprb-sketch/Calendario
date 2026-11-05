import SwiftUI
struct ObligationsView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: Obligation?
    var openOld: [Obligation] { store.obligations.filter { $0.origin_week_start < store.week && $0.status != "completed" } }
    var body: some View {
        NavigationStack {
            List {
                Section("Nuovi · settimana del \(store.week)") {
                    ForEach(store.obligations.filter { $0.origin_week_start == store.week }) { slot in row(slot) }
                }
                Section("Arretrati · \(openOld.count)") {
                    if openOld.isEmpty { Text("Nessun impegno arretrato").foregroundStyle(.secondary) }
                    ForEach(openOld) { slot in row(slot) }
                }
                Section("Da confermare") { ForEach(store.incoming) { request in ReviewRow(request:request) } }
                Section { Text("Le richieste in attesa restano aperte. Solo la conferma del partner completa un impegno. Gli arretrati mantengono la settimana originale.").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("I vostri impegni").refreshable { await store.refresh() }
                .sheet(item:$selected) { slot in ObligationEditor(slotID:slot.id) }
        }
    }
    func row(_ slot: Obligation) -> some View {
        VStack(alignment:.leading,spacing:6) {
            HStack { Text(store.person(slot.owner_id)).font(.caption.bold()).foregroundStyle(.indigo); Spacer(); Text("#\(slot.slot_index)").font(.caption) }
            Text(store.title(slot)).font(.headline)
            Text(slot.statusLabel).foregroundStyle(slot.status == "completed" ? .green : .secondary)
            if slot.origin_week_start < store.week { Text("Origine: \(slot.origin_week_start)").font(.caption).foregroundStyle(.orange) }
            if slot.owner_id == store.userID && slot.status != "completed" && slot.status != "pending_confirmation" {
                Button(slot.event_id == nil ? "Scegli la tua attività" : "Gestisci") { selected=slot }.buttonStyle(.borderless)
            }
        }.padding(.vertical,5)
    }
}
struct ObligationEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let slotID: UUID
    @State private var eventID: UUID?
    @State private var kind = "personal"
    @State private var note = ""
    @State private var newEvent = false
    var slot: Obligation? { store.obligations.first { $0.id == slotID } }
    var body: some View {
        NavigationStack {
            Form {
                if let slot {
                    Section("Associa un evento di cui sei responsabile") {
                        Picker("Attività",selection:$eventID) {
                            Text("Seleziona").tag(nil as UUID?)
                            ForEach(store.events.filter { $0.owner_id == store.userID }) { e in Text(e.title).tag(e.id as UUID?) }
                        }
                        Button("Crea una nuova attività") { newEvent=true }
                        Picker("Tipo",selection:$kind) { Text("Personale").tag("personal"); Text("Di coppia").tag("couple") }
                        Text("Un impegno di coppia richiede un evento condiviso con entrambi i partecipanti.").font(.caption)
                        Button("Associa attività") { if let eventID { Task { await store.assign(slot,event:eventID,kind:kind) } } }.disabled(eventID == nil || store.busy)
                    }
                    if slot.event_id != nil && ["scheduled","disputed"].contains(slot.status) {
                        Section("Richiedi la conferma del partner") {
                            TextField("Nota facoltativa",text:$note,axis:.vertical)
                            Button("Ho completato questo impegno") { Task { await store.request(slot,note:note); if store.error == nil { dismiss() } } }.disabled(store.busy || store.people.count<2)
                        }
                    }
                    Text(slot.statusLabel).font(.caption)
                }
            }.navigationTitle("Il tuo impegno").toolbar { Button("Chiudi") { dismiss() } }
                .onAppear { eventID=slot?.event_id; kind=slot?.kind ?? "personal" }
                .sheet(isPresented:$newEvent) { EventEditor(event:nil) }
        }
    }
}
