# Coppia — Calendario di coppia, MVP v1

App nativa per iOS 17+, SwiftUI e Supabase. Ogni persona sceglie i propri impegni; il partner ne conferma il completamento. Interfaccia italiana, settimana ISO e fuso Europe/Rome predefinito.

**Stato della consegna:** codice e repository Git locali creati. Non è una release validata per distribuzione: in questo ambiente mancano Xcode, PostgreSQL e Supabase CLI; il proxy di rete non è raggiungibile. I test di integrazione e i test iOS sono inclusi ma non sono stati eseguiti qui. Nessun database remoto è stato creato o modificato. Repository GitHub: https://github.com/qygttqnprb-sketch/Calendario.

## Contenuto

- `ios/Coppia`: app SwiftUI con store MVVM, Auth email/password, creazione coppia/invito, riepilogo, calendario mese/settimana/giorno, editor, impegni, revisioni e impostazioni.
- `supabase/migrations`: schema, RLS, RPC transazionali, feed di invalidazione Realtime e scheduler pg_cron.
- `scripts/test_database.py`: test su PostgreSQL reale, con tre identità, RLS e richieste concorrenti.
- `ios/CoppiaTests`: date, cambio ora, confine anno ISO e URL.
- `.github/workflows/ci.yml`: verifiche PostgreSQL e build/test iOS su macOS.

## Avvio su Mac

Richiede Xcode 16+, XcodeGen e Supabase CLI. Installare gli strumenti secondo la loro documentazione; per XcodeGen è disponibile `brew install xcodegen`.

1. Crea un progetto Supabase dedicato, oppure avvia lo stack locale con `supabase start`. Non utilizzare un database con dati esistenti: le migrazioni sono per un progetto nuovo.
2. Per il progetto remoto, verifica la CLI con `supabase --help`, poi `supabase link --help`, `supabase db push --help`. Collega il progetto e applica entrambe le migrazioni con `supabase db push`. La seconda richiede pg_cron, disponibile su Supabase.
3. In Supabase Auth abilita email/password, configura SMTP per l’ambiente di produzione e il flusso di conferma email. Dopo la conferma l’utente torna nell’app ed esegue il login. Per Realtime assicurati che `couple_changes` appartenga alla pubblicazione `supabase_realtime` (la prima migrazione lo imposta).
4. Copia `ios/Config.example.xcconfig` in `ios/Config.xcconfig`. Inserisci URL HTTPS e **chiave `sb_publishable_…`**. L’app accetta esclusivamente questo formato; nessuna chiave segreta è necessaria nel client.
5. Da `ios`, esegui `xcodegen generate` e apri `Coppia.xcodeproj`. Scegli il tuo team Apple per installare su dispositivo; il simulatore non richiede firma.
6. Risolvi i pacchetti in Xcode e conserva in Git il `Package.resolved` prodotto, prima di una release. Supabase Swift è vincolato alla versione esatta `2.30.0`; la risoluzione e compatibilità devono essere verificate con la build CI. La CLI non era disponibile per generare le migrazioni: i file SQL sono stati preparati manualmente e vanno validati con `supabase db reset` sullo stack locale.

Lo stack locale espone HTTP; per provarlo su dispositivo servono un endpoint HTTPS raggiungibile e la relativa configurazione. Non disattivare TLS sul progetto remoto.

## Regole implementate

La membership è unica per utente e una coppia ammette al massimo due membri. Gli inviti contengono 128 bit casuali, sono memorizzati solo come hash, scadono dopo 24 ore e vengono consumati atomicamente. Un nuovo invito invalida quelli precedenti della stessa coppia.

`ensure_weekly_slots` accetta solo la settimana locale corrente, ricavata dal server. La chiave univoca impedisce duplicati; un record interno conserva la quota della settimana, anche se le impostazioni cambiano. Se il partner entra più tardi nella settimana ottiene la stessa quota. Il job pg_cron gira ogni minuto: gli slot compaiono dal primo passaggio dopo la mezzanotte locale del lunedì, anche con app chiusa. L’apertura dell’app richiama la stessa funzione come recupero idempotente. Non viene fatto un recupero retroattivo delle settimane durante cui il database era fermo.

Gli arretrati sono gli stessi record con `origin_week_start` precedente e stato diverso da `completed`, compresi gli slot ancora vuoti. Non vengono copiati. Cambiare fuso applica immediatamente la settimana ISO locale; i record precedenti mantengono la loro data di origine. La quota modificata vale solo per settimane non ancora generate. Le opzioni settimana di lunedì, riporto e conferma reciproca sono fisse in v1.

Solo il proprietario associa un proprio evento a uno slot; uno stesso evento non può soddisfare più slot. Gli eventi di coppia richiedono privacy condivisa e due partecipanti. Richiedere conferma non completa l’impegno. Solo il partner designato può approvare o contestare. La contestazione porta a `disputed`, con possibilità di ripresentazione. Lock di riga, indice delle richieste pendenti e audit nella stessa transazione impediscono doppie conferme. Gli eventi associati a impegni in conferma o completati non possono essere modificati.

## Privacy e sicurezza

Tutte le tabelle applicative, incluse quelle interne, hanno RLS. I client hanno solo accesso in lettura alle tabelle: ogni scrittura passa da RPC. Le funzioni con privilegi elevati sono nello schema non esposto `private`, con `search_path` vuoto, autorizzazione esplicita e grant limitati. Gli endpoint pubblici sono wrapper `security invoker`.

La tabella `events` rivela al partner solo gli eventi condivisi. `calendar_events` restituisce anche i periodi `busy_only`, redigendo titolo, descrizione, luogo e URL sul server. Gli eventi privati del partner sono esclusi. Partecipanti e link ereditano la visibilità dell’evento. Lo slot può mostrare che esiste un’attività riservata, senza i suoi dettagli.

Realtime pubblica soltanto la revisione della coppia, senza titoli, note o corpi degli eventi. Il client ricarica i dati attraverso RLS/RPC dopo la notifica, anche quando cambia la privacy di un evento. Il database non pubblica payload degli eventi.

I link vengono validati sintatticamente come HTTPS senza credenziali, porte o whitespace. Non vengono richiesti dal server e non ne viene garantita disponibilità o autenticità commerciale. TheFork, Too Good To Go e mappe si aprono come link esterni; non esistono prenotazioni automatiche o integrazioni API implicite.

## Notifiche ed EventKit

Il promemoria settimanale locale richiede il consenso iOS ed è programmato per lunedì alle 09:00 nel fuso della coppia. Viene rimosso all’uscita. Le richieste del partner sono visibili in app via Realtime; **le notifiche push APNs in background non sono incluse**.

EventKit è un’esportazione manuale a senso unico, solo dopo conferma e permesso iOS. Esporta i propri eventi attualmente caricati. Un identificatore locale per utente/evento e un URL di sincronizzazione consentono di aggiornare le esportazioni ripetute senza creare copie nel normale utilizzo. Se l’identificatore cambia, il recupero cerca il marker nella finestra temporale dell’evento. Spostamenti manuali in Apple insieme a cambi di identificatore possono richiedere riconciliazione: non è una sincronizzazione bidirezionale. Gli eventi esportati assumono la privacy del calendario Apple di destinazione.

## Verifica

Per i test database usa **solo un database PostgreSQL vuoto e sacrificabile**, con un utente amministratore: il bootstrap crea ruoli e lo schema Auth di prova. Non puntarlo al progetto Supabase o alla produzione.

```sh
DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres python3 scripts/test_database.py
```

Il test usa `psql` e Python standard. Simula `auth.uid()` e i ruoli reali del Data API, senza sostituire o simulare il motore SQL. Copre isolamento del terzo account, dettagli privati e occupato, scritture dirette vietate, assegnazione autonoma, doppia generazione concorrente, conferma concorrente, contestazione/ripresentazione, arretrati, quota congelata, DST, anno ISO e link non HTTPS. Il job PostgreSQL CI verifica la prima migrazione; lo scheduler pg_cron va verificato sullo stack Supabase locale o di staging.

Da Xcode esegui lo scheme `Coppia` con Test, oppure usa la CI macOS. Prima di una release esegui anche `supabase db reset`, gli advisor di sicurezza disponibili nella versione CLI installata e la prova manuale seguente.

1. Registra Alice e Bob; crea la coppia e unisci Bob con il codice.
2. Crea un evento condiviso da Alice e verifica l’aggiornamento su Bob senza riavvio.
3. Crea eventi privato e occupato: Bob vede solo il periodo dell’occupato; un terzo account non vede dati della coppia.
4. Verifica due slot per persona e la stabilità del conteggio dopo refresh ripetuti.
5. Associa un’attività, richiedi conferma, contesta da Bob e ripresenta da Alice; soltanto l’approvazione finale completa lo slot.
6. In staging verifica il passaggio domenica/lunedì nel fuso della coppia e il job cron; lo slot incompleto mantiene UUID e settimana originali.

## Passaggi rimasti per la distribuzione

Build e test su Xcode/Supabase, credenziali pubbliche del progetto, configurazione SMTP, firma Apple, icona e materiali App Store. Inviti e Auth devono avere rate limiting operativo prima dell’apertura al pubblico. Il consenso EventKit e le regole della settimana richiedono anche verifica su dispositivi reali. Nessuna funzione IA è inclusa.
