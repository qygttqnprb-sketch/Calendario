# Coppia — Calendario di coppia, MVP v1

App nativa per iOS 17+, SwiftUI e Supabase. Ogni persona sceglie i propri impegni; il partner ne conferma il completamento. Interfaccia italiana, settimana ISO e fuso Europe/Rome predefinito.

**Stato:** backend Supabase attivo e migrazioni applicate; test PostgreSQL CI (10/10) e test di accettazione sul database reale superati. Il test reale usa fixture transazionali e lascia il database senza utenti o eventi di prova. Advisor di sicurezza senza segnalazioni. La build/test iOS viene verificata dalla CI macOS; il risultato aggiornato è nella pagina [Actions](https://github.com/qygttqnprb-sketch/Calendario/actions). Non è ancora una release App Store.

Repository: https://github.com/qygttqnprb-sketch/Calendario. Backend: [dashboard Supabase Calendario](https://supabase.com/dashboard/project/hibizgelxgkixviferoo), regione Irlanda (`eu-west-1`). Lo scheduler è attivo ogni minuto e Realtime pubblica `couple_changes`.

## Contenuto

- `ios/Coppia`: app SwiftUI con store MVVM, Auth email/password, creazione coppia/invito, riepilogo, calendario mese/settimana/giorno, editor, impegni, revisioni e impostazioni.
- `supabase/migrations`: schema, RLS, RPC transazionali, feed di invalidazione Realtime e scheduler pg_cron.
- `scripts/test_database.py`: test su PostgreSQL reale, con tre identità, RLS e richieste concorrenti.
- `ios/CoppiaTests`: date, cambio ora, confine anno ISO e URL.
- `.github/workflows/ci.yml`: verifiche PostgreSQL e build/test iOS su macOS.

## Avvio su Mac

Richiede Xcode 16+, XcodeGen e Supabase CLI. Installare gli strumenti secondo la loro documentazione; per XcodeGen è disponibile `brew install xcodegen`.

Il progetto remoto è già configurato. Su Mac:

```sh
brew install xcodegen
bash scripts/setup_ios.sh
open ios/Coppia.xcodeproj
```

Lo script copia `ios/Config.public.xcconfig` in `ios/Config.xcconfig` solo se il file locale non esiste, quindi genera il progetto. Il file pubblico contiene esclusivamente URL e chiave pubblicabile del backend; la sicurezza dei dati è affidata a RLS e alle RPC autenticate. Scegli il team Apple e lo scheme `Coppia` per l’installazione su iPhone; il simulatore non richiede firma.

Per usare un altro progetto, modifica il file locale ignorato `Config.xcconfig`. Su un nuovo database Supabase applica tutte le migrazioni in ordine. I nomi delle migrazioni nel repository corrispondono alla storia registrata nel progetto remoto; non riapplicarle manualmente al progetto già configurato. Verifica i comandi disponibili con `supabase --help` e `supabase db push --help`.

Auth usa email/password. Dopo la conferma email torna nell’app ed esegui il login; per l’apertura al pubblico restano da configurare SMTP e una destinazione definitiva della pagina di conferma. Le credenziali degli utenti non vengono incluse nel repository. Supabase Swift è fissato alla versione esatta `2.30.0`. La CI conserva il risultato dei test iOS e registra la risoluzione delle dipendenze.

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

Il test usa `psql` e Python standard. Simula `auth.uid()` e i ruoli reali del Data API, senza sostituire o simulare il motore SQL. Copre isolamento del terzo account, dettagli privati e occupato, scritture dirette vietate, assegnazione autonoma, doppia generazione concorrente, conferma concorrente, contestazione/ripresentazione, arretrati, quota congelata, DST, anno ISO e link non HTTPS. Il job PostgreSQL CI verifica schema, ottimizzazioni RLS e test di accettazione. Sul progetto remoto sono state applicate tutte le migrazioni, verificati job pg_cron e pubblicazione Realtime, ed eseguito lo stesso smoke test con rollback. La consegna in tempo reale fra due client iOS e l’invio email Auth richiedono ancora una prova integrata.

Il test transazionale `supabase/tests/live_acceptance.sql` può essere rieseguito da un amministratore su staging: verifica privacy e transizioni e annulla tutte le fixture. Non sostituisce la prova di concorrenza su connessioni indipendenti, eseguita dai test Python.

Da Xcode esegui lo scheme `Coppia` con Test, oppure usa la CI macOS. Prima di una release esegui anche `supabase db reset`, gli advisor di sicurezza disponibili nella versione CLI installata e la prova manuale seguente.

1. Registra Alice e Bob; crea la coppia e unisci Bob con il codice.
2. Crea un evento condiviso da Alice e verifica l’aggiornamento su Bob senza riavvio.
3. Crea eventi privato e occupato: Bob vede solo il periodo dell’occupato; un terzo account non vede dati della coppia.
4. Verifica due slot per persona e la stabilità del conteggio dopo refresh ripetuti.
5. Associa un’attività, richiedi conferma, contesta da Bob e ripresenta da Alice; soltanto l’approvazione finale completa lo slot.
6. In staging verifica il passaggio domenica/lunedì nel fuso della coppia e il job cron; lo slot incompleto mantiene UUID e settimana originali.

## Passaggi rimasti per la distribuzione

Prova integrata su due dispositivi, configurazione SMTP e redirect email, firma Apple, icona e materiali App Store. Inviti e Auth devono avere rate limiting operativo prima dell’apertura al pubblico. Il consenso EventKit e le regole della settimana richiedono anche verifica su dispositivi reali. Nessuna funzione IA è inclusa.
