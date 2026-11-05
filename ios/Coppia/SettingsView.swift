import SwiftUI
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var zone="Europe/Rome"
    @State private var quota=2
    @AppStorage("weeklyNotifications") private var notifications=false
    @State private var exportConsent=false
    var body: some View {
        NavigationStack {
            Form {
                Section("La vostra settimana") {
                    Picker("Fuso orario",selection:$zone) { ForEach(TimeZone.knownTimeZoneIdentifiers,id:\.self) { Text($0).tag($0) } }
                    Stepper("Nuovi impegni a persona: \(quota)",value:$quota,in:1...10)
                    Text("Settimana ISO: lunedì. La quota modificata vale per le settimane ancora da generare. Gli arretrati restano aperti.").font(.caption).foregroundStyle(.secondary)
                    Button("Salva impostazioni") { Task {
                        await store.settings(zone:zone,quota:quota)
                        if notifications { do { try await DeviceServices.weeklyReminder(enabled:true,zone:zone) } catch { store.error=error.localizedDescription } }
                    } }.disabled(store.busy)
                }
                Section("Su questo dispositivo") {
                    Toggle("Promemoria del lunedì alle 09:00",isOn:$notifications)
                        .onChange(of:notifications) { _,on in Task { do { try await DeviceServices.weeklyReminder(enabled:on,zone:store.timezone) } catch { notifications=false; store.error=error.localizedDescription } } }
                    Button("Esporta i miei eventi in Calendario Apple") { exportConsent=true }
                    Text("Esportazione manuale degli eventi caricati nel calendario. Ripetendola aggiorni gli stessi eventi; le modifiche in Apple non tornano nell’app.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Text("Privato: solo tu. Solo occupato: il partner vede l’orario. Condiviso: entrambi vedete i dettagli.")
                    Text("Ogni impegno ha un solo responsabile. Il partner deve confermare il completamento.")
                }
                Section {
                    Button("Esci",role:.destructive) { Task {
                        try? await DeviceServices.weeklyReminder(enabled:false,zone:store.timezone)
                        notifications=false; await store.logout()
                    } }
                }
            }.navigationTitle("Impostazioni").onAppear { zone=store.timezone; quota=store.quota }
                .confirmationDialog("Consenti l’accesso al Calendario Apple ed esporta i tuoi eventi?",isPresented:$exportConsent,titleVisibility:.visible) {
                    Button("Consenti ed esporta") { Task {
                        guard let user=store.userID else { return }
                        await store.run { try await DeviceServices.export(events:store.events,user:user); store.notice="Eventi esportati in Calendario Apple." }
                    } }
                    Button("Annulla",role:.cancel) { }
                } message: { Text("Gli eventi esportati saranno visibili alle persone con cui condividi il calendario Apple di destinazione.") }
        }
    }
}
