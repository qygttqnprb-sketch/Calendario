import SwiftUI

@main struct CoppiaApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(.indigo)
                .task { await store.start() }
                .onChange(of: phase) { _, value in if value == .active { Task { await store.refresh(); await store.listen() } } }
                .alert("Qualcosa non è riuscito", isPresented: Binding(get:{store.error != nil},set:{if !$0 {store.error=nil}})) { Button("OK") { store.error=nil } } message: { Text(store.error ?? "") }
                .alert("Account", isPresented: Binding(get:{store.notice != nil},set:{if !$0 {store.notice=nil}})) { Button("OK") { store.notice=nil } } message: { Text(store.notice ?? "") }
        }
    }
}
struct RootView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Group {
            if store.client == nil {
                ContentUnavailableView("Configura Supabase", systemImage:"gearshape.2", description:Text("Copia Config.example.xcconfig in Config.xcconfig e inserisci URL e chiave pubblicabile del progetto."))
            } else if !store.ready { ProgressView("Apro il vostro spazio…") }
            else if store.userID == nil { AuthView() }
            else if store.couple == nil { OnboardingView() }
            else {
                TabView {
                    HomeView().tabItem { Label("Insieme", systemImage:"heart") }
                    CalendarScreen().tabItem { Label("Calendario", systemImage:"calendar") }
                    ObligationsView().tabItem { Label("Impegni", systemImage:"checkmark.circle") }
                    SettingsView().tabItem { Label("Impostazioni", systemImage:"gearshape") }
                }
            }
        }.overlay(alignment:.top) { if store.busy { ProgressView().padding(10).background(.regularMaterial,in:Capsule()) } }
    }
}
struct AuthView: View {
    @EnvironmentObject var store: AppStore
    @State private var email = ""
    @State private var password = ""
    @State private var signup = false
    var body: some View {
        NavigationStack {
            Form {
                Section { Label("Il tempo per voi due.",systemImage:"heart.circle.fill").font(.title2).padding(.vertical) }
                Section("Il tuo account") {
                    TextField("Email",text:$email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password",text:$password).textContentType(signup ? .newPassword : .password)
                    Toggle("Crea un nuovo account",isOn:$signup)
                    Button(signup ? "Registrati" : "Accedi") { Task { await store.authenticate(email:email,password:password,signup:signup) } }.disabled(store.busy || email.isEmpty || password.count < 8)
                }
            }.navigationTitle("Coppia")
        }
    }
}
struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    @State private var name = ""
    @State private var coupleName = "Il nostro calendario"
    @State private var code = ""
    @State private var joining = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Presentati") { TextField("Il tuo nome",text:$name) }
                Section("Il vostro spazio") {
                    Toggle("Ho un codice invito",isOn:$joining)
                    if joining { TextField("Codice monouso",text:$code).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    else { TextField("Nome della coppia",text:$coupleName) }
                    Button(joining ? "Unisciti al partner" : "Crea la coppia") {
                        Task { await store.onboard(name:name,coupleName:coupleName,code:joining ? code : "") }
                    }.disabled(store.busy || name.trimmingCharacters(in:.whitespaces).isEmpty || (joining ? code.isEmpty : coupleName.isEmpty))
                }
                Button("Esci",role:.destructive) { Task { await store.logout() } }
            }.navigationTitle("Cominciamo da voi")
        }
    }
}
struct HomeView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment:.leading,spacing:12) {
                        Text("Un po’ di organizzazione.\nPiù tempo insieme.").font(.title2.bold())
                        Text("Settimana del \(store.week) · \(store.timezone)").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical,8)
                }
                Section("Questa settimana") {
                    ForEach(store.people) { person in
                        let slots = store.obligations.filter { $0.owner_id == person.id }
                        let current = slots.filter { $0.origin_week_start == store.week }
                        let old = slots.filter { $0.origin_week_start < store.week && $0.status != "completed" }
                        VStack(alignment:.leading,spacing:6) {
                            Text(person.display_name).font(.headline)
                            Text("\(current.filter { $0.status == "completed" }.count) di \(current.count) nuovi impegni confermati")
                            if !old.isEmpty { Text("\(old.count) arretrati aperti").foregroundStyle(.orange) }
                        }.padding(.vertical,4)
                    }
                }
                Section("Da confermare · \(store.incoming.count)") {
                    if store.incoming.isEmpty { Text("Nessuna richiesta in attesa").foregroundStyle(.secondary) }
                    ForEach(store.incoming) { request in ReviewRow(request:request) }
                }
                if store.people.count < 2 {
                    Section("Invita il tuo partner") {
                        Button("Genera codice valido 24 ore") { Task { await store.invite() } }.disabled(store.busy)
                        if let code=store.inviteCode { Text(code).font(.system(.footnote,design:.monospaced)).textSelection(.enabled); ShareLink(item:code) { Label("Condividi codice",systemImage:"square.and.arrow.up") } }
                    }
                }
            }.navigationTitle(store.couple?.name ?? "Insieme").refreshable { await store.refresh() }
        }
    }
}
struct ReviewRow: View {
    @EnvironmentObject var store: AppStore
    let request: CompletionRequest
    @State private var note = ""
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(store.obligations.first { $0.id == request.obligation_id }.map { store.title($0) } ?? "Impegno").font(.headline)
            Text("Richiesta di \(store.person(request.requested_by))").font(.caption).foregroundStyle(.secondary)
            if !request.note.isEmpty { Text(request.note) }
            TextField("Nota per il partner (facoltativa)",text:$note)
            HStack {
                Button("Conferma",systemImage:"checkmark") { Task { await store.review(request,approve:true,note:note) } }.buttonStyle(.borderedProminent)
                Button("Contesta",systemImage:"arrow.uturn.backward") { Task { await store.review(request,approve:false,note:note) } }.buttonStyle(.bordered)
            }.disabled(store.busy)
        }.padding(.vertical,6)
    }
}
