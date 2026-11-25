# Studio — Un Google Calendar completo dentro MishMail

Data: 25 novembre 2026
Stato: studio, nessun codice. Nulla si costruisce finché il client di posta non è completo e stabile per l'uso quotidiano.
Fonti: documentazione di Google e di Apple letta il 25 novembre 2026 (elenco nella sezione 9). Dove un'affermazione non è stata trovata nella documentazione è scritto **non verificato**.

## Sintesi

**Risposta.** Si può fare, con la Google Calendar API, senza server e senza nuove dipendenze. La parte più grande non è l'API: è l'interfaccia (viste giorno/settimana/mese, modifica degli eventi ricorrenti) e la sincronizzazione locale. Alcune cose di Google Calendar web non sono raggiungibili da nessun client di terze parti: agende di appuntamenti (pagine di prenotazione), "proponi un nuovo orario", Time Insights, l'orario dei task.

**Raccomandazione.** Usare la Calendar API di Google, non EventKit di Apple. Procedere a passi, ciascuno utile da solo:

1. accendere ciò che c'è già (perimetro B, PR #55 e #57) dopo la prova C-45;
2. pannello agenda in sola lettura, con copia locale cifrata e sincronizzazione incrementale;
3. promemoria degli eventi, generici per impostazione predefinita;
4. creazione e modifica di eventi semplici (anche da un messaggio), con invitati e link Meet;
5. finestra calendario completa (viste, ricorrenze, più calendari, trova un orario, ricerca, modifiche offline);
6. task, per ultimi, con la Tasks API.

**I fatti che decidono.**

- **Il permesso già scelto basta quasi per tutto.** `calendar.events`, `calendar.events.freebusy` e `calendar.calendarlist.readonly` (DEC-048) coprono lettura e scrittura degli eventi, elenco e colori dei calendari, libero/occupato, link Meet. Ogni permesso in più (impostazioni, task, gestione dei calendari) vuol dire un nuovo consenso per ogni account, perché Google non consente di estendere un consenso alle app desktop.
- **Niente notifiche push senza un server.** Google le consegna solo a un indirizzo HTTPS pubblico con certificato valido. MishMail deve interrogare Google a intervalli, come già fa per la posta. Con i token di sincronizzazione il costo è basso: una richiesta per calendario a ogni giro, contro un limite di 600 richieste al minuto per utente.
- **EventKit non può dare un calendario "come Gmail".** Non permette di aggiungere invitati né di rispondere a un invito, non crea link Meet, non vede libero/occupato degli altri, e richiede che l'utente aggiunga l'account Google in macOS con un consenso separato. I dati starebbero fuori dal database cifrato di MishMail.
- **Nessun ambito Calendar è "restricted".** La lettura degli eventi è "sensitive". Finché ognuno usa il proprio client OAuth (registro, sezione 6) Google non deve approvare nulla. Con un client condiviso servirebbe la verifica degli ambiti sensibili (video dimostrativo, giustificazione), non un nuovo assessment di sicurezza: quello dipende già da Gmail.

**Cosa fare adesso.** Quasi nulla: il codice di oggi è già ben isolato. Le poche attenzioni sono nella sezione 6. Le domande per il proprietario sono nella sezione 7.

---

## 1. Che cosa offre Google e che cosa copre l'API

### 1.1 Il pannello Calendar dentro Gmail

La guida di Google dice solo: "Calendar: Check your schedule and add or edit events", e che un evento si crea con un clic su un orario. Quali viste offra il pannello e se permetta di rispondere a un invito **non è scritto** nella pagina letta (non verificato; nella pratica mostra un giorno alla volta).

### 1.2 Google Calendar sul web, funzione per funzione

Legenda: **Sì** = coperto dalla Calendar API v3; **Parziale** = coperto con limiti; **No** = nessuna API trovata.

| Funzione | API | Come, e limiti |
|---|---|---|
| Viste giorno, settimana, mese, anno, agenda, 4 giorni | Sì (dati) | Le viste sono interfaccia nostra; i dati vengono da `events.list`. |
| Creare, modificare, cancellare, spostare eventi | Sì | `events.insert/update/patch/delete/move`, `quickAdd` (testo libero). `patch` costa tre unità di quota; Google consiglia `get` più `update`. |
| Eventi ricorrenti | Sì | Regole RFC 5545 nel campo `recurrence`. `singleEvents=true` fa espandere le occorrenze a Google; `events.instances` elenca quelle di una serie. |
| Eccezioni a una serie | Sì | Un'occorrenza modificata è un evento con `recurringEventId` e `originalStartTime`; una cancellata ha `status: cancelled`. |
| "Questo e i successivi" | Parziale | La guida attuale avverte solo di non modificare le occorrenze una per una. Il procedimento (accorciare la serie con UNTIL e crearne una nuova) non è più nella pagina: non verificato. |
| Invitati e risposte | Sì | `attendees[]` con `responseStatus`, `optional`, `comment`, `additionalGuests`. Permessi degli ospiti: `guestsCanModify`, `guestsCanInviteOthers`, `guestsCanSeeOtherGuests`. Fino a 200 invitati. `sendUpdates` decide se Google avvisa per e-mail. |
| Proporre un nuovo orario | No | Esiste nell'interfaccia; nessun campo o metodo nel riferimento dell'API (non verificato come divieto esplicito). Resta la strada iTIP `COUNTER` per e-mail, che oggi il parser riconosce ma non genera. |
| Sale e risorse | Parziale | Prenotare: si aggiunge l'indirizzo della sala come invitato. Elencare le sale: solo Admin SDK, con un ambito da amministratore; se un utente normale possa chiamarlo non è verificato. |
| Link Meet | Sì | `conferenceData.createRequest` con `conferenceDataVersion=1`. Nessun ambito in più. La Meet API serve solo per gestire le stanze (registrazioni, impostazioni): non occorre. |
| Più calendari e colori | Sì | `calendarList` dà colore, visibilità (`selected`, `hidden`), ruolo, promemoria predefiniti. Leggere basta `calendarlist.readonly`; cambiare colore o visibilità su Google richiede `calendar.calendarlist`. Novità 2026: etichette degli eventi (`eventLabelId`) al posto di `colorId`. |
| Calendari condivisi e sottoscritti | Sì | Compaiono in `calendarList` con il loro `accessRole` (`freeBusyReader`, `reader`, `writerWithoutPrivateAccess`, `writer`, `owner`). Sottoscrivere: `calendarList.insert`. Condividere: `acl`, con l'ambito `calendar.acls`. Creare calendari: `calendar.calendars`. |
| Fusi orari | Sì | Nomi IANA in `start/end.timeZone`, obbligatori per le serie. Il fuso secondario e l'orologio mondiale non sono tra le impostazioni esposte: sarebbero impostazioni locali. |
| Eventi di tutto il giorno | Sì | `start.date`/`end.date`, fine esclusa, senza fuso. |
| Impostazioni dell'utente | Parziale | Sola lettura (`settings`): fuso, inizio settimana, formato 24 ore, durata predefinita, mostra eventi rifiutati, nascondi fine settimana. Serve `calendar.settings.readonly`. |
| Promemoria | Parziale | L'API li conserva (`reminders.overrides`, al massimo 5, e `defaultReminders` del calendario). Non li consegna: Google manda i pop-up solo ai propri client. MishMail dovrebbe programmare notifiche locali. |
| Libero/occupato | Sì | `freebusy.query`, fino a 50 calendari per richiesta. Già usato da #55. |
| Trova un orario | Parziale | Nessun metodo REST. Si costruisce sopra `freebusy.query` (il web confronta fino a 50 invitati). Lo strumento `suggest_time` esiste solo nel server MCP di Calendar, riservato ai client dichiarati come agenti AI. |
| Task | Parziale | Non sono nella Calendar API. Tasks API, ambito `tasks`. Limite: `due` porta solo la data ("It isn't possible to read or write the time that a task is scheduled for using the API"), quindi un task non si può mettere alla sua ora come fa il web. I task assegnati da Docs e Chat si leggono (`showAssigned`). |
| Sede di lavoro, fuori sede, tempo di concentrazione | Parziale | `eventType` `workingLocation`, `outOfOffice`, `focusTime`, creabili con `events.insert`, solo sul calendario principale e solo per alcune edizioni di Workspace. Orario di lavoro: proprietà `workingHours` del calendario (novembre 2026). |
| Compleanni | Parziale | `eventType: birthday`: si creano; di quelli legati a un contatto si cambiano solo colore, titolo, promemoria. |
| Eventi da Gmail | Parziale | `eventType: fromGmail`: si leggono e si cancellano, non si creano. Nello Spazio economico europeo sono spenti per impostazione predefinita. |
| Agende di appuntamenti (pagine di prenotazione) | No | Nessuna risorsa nel riferimento dell'API né nelle note di rilascio (un "non esiste" ufficiale non è stato trovato: non verificato). |
| Ricerca | Parziale | `events.list?q=` cerca in titolo, descrizione, luogo, invitati, organizzatore, per singolo calendario. Non si combina con il token di sincronizzazione. Una ricerca offline richiede un indice locale. |
| Allegati | Sì | Collegamenti a file di Drive, al massimo 25. Scegliere un file da Drive richiederebbe un ambito Drive: fuori perimetro. |
| Time Insights | No | Solo interfaccia web, account di lavoro. |
| Offline | — | Il web offline funziona solo in Chrome e in sola lettura. Un client nativo può fare di più (sezione 2.6). |

### 1.3 Ambiti e loro classe

La pagina degli ambiti di Calendar e quella di Tasks oggi **non riportano più la classe** (non-sensitive, sensitive, restricted) per singolo ambito: Google rimanda alla Cloud Console, che la mostra quando l'ambito viene aggiunto al progetto. Ciò che è verificato:

- nessun ambito Calendar o Tasks è nell'elenco dei **restricted** (che copre Gmail, Drive, Fit, Chat, Data Portability, Photos, Health);
- leggere gli eventi è indicato da Google come esempio di ambito **sensitive**;
- se gli ambiti stretti (`calendar.calendarlist.readonly`, `calendar.events.freebusy`, `calendar.settings.readonly`, `calendar.app.created`) siano non-sensitive: **non verificato**; si vede nella Cloud Console del proprio progetto.

| Ambito | A che serve | Oggi in MishMail |
|---|---|---|
| `calendar.events` | Leggere e modificare eventi su tutti i calendari | Sì (DEC-048) |
| `calendar.events.freebusy` | Libero/occupato | Sì |
| `calendar.calendarlist.readonly` | Elenco, colori, ruoli dei calendari | Sì |
| `calendar.settings.readonly` | Fuso, inizio settimana, formato ora | No |
| `calendar.calendarlist` | Cambiare colore e visibilità, sottoscrivere | No |
| `calendar.calendars` | Creare e cancellare calendari | No |
| `calendar.acls` | Condividere calendari | No |
| `calendar` | Tutto quanto sopra | No, mai chiesto |
| `tasks` | Task (Tasks API) | No |
| `meetings.space.created` (Meet API, sensitive) | Gestire stanze Meet | Non serve |

### 1.4 Verifica da parte di Google

- **Oggi nulla.** Il registro (sezione 6, punto 4) dice che ognuno porta il proprio client OAuth. In quel modello Google non approva niente.
- **Modalità del progetto OAuth.** In *Testing*: al massimo 100 utenti di prova e consenso che scade dopo 7 giorni; vale anche per il token Calendar, perché l'eccezione riguarda solo nome, e-mail e profilo. *In production* senza verifica: schermata "app non verificata" e tetto di 100 utenti per l'intera vita del progetto. Nuova modalità *Personal*: nessuna verifica, nessuna scadenza a 7 giorni, nessuna schermata di avviso, ma solo per l'unico account Google che ha creato il progetto, e non si può convertire. Per un uso con più account non basta.
- **Con un client condiviso.** Per gli ambiti sensibili: verifica del marchio (dominio di proprietà, home page, privacy policy), giustificazione di ogni ambito, video dell'intero flusso. Tempi dichiarati: 2–3 giorni lavorativi per il marchio, 10 per gli ambiti sensibili. L'assessment di sicurezza annuale (CASA) è richiesto solo per gli ambiti restricted: Calendar non lo aggiunge, Gmail lo porta già.
- **Aggiungere un ambito a un'app già verificata** richiede la verifica di quell'ambito; non di rifare l'assessment. Conviene quindi presentare gli ambiti Calendar insieme a quelli Gmail, se mai si chiederà la verifica.
- Se un'app che tiene i dati solo sul dispositivo sia esente da CASA: le pagine legano l'obbligo all'accesso "da o attraverso un server", ma una frase esplicita di esenzione non c'è (non verificato). Riguarda Gmail, non Calendar.

### 1.5 Quote e costi

- Calendar API: **600 richieste al minuto per utente**, **10.000 al minuto per progetto**, finestra scorrevole. Nessun limite giornaliero pubblicato.
- Dal 2026 esistono due livelli: *Standard*, gratuito ("never produces charges"), e *Scaled*, a pagamento su richiesta. I limiti Standard valgono per tutti i progetti dal 1° aprile 2027. Sul livello Standard non si possono chiedere aumenti.
- Errori di quota: 403 o 429 `usageLimits`; Google chiede backoff esponenziale troncato. Il client di #55 li traduce già in `rateLimited` e legge `Retry-After`.
- Tasks API: 50.000 richieste al giorno (limite "di cortesia").
- Dal 1° febbraio 2027 gli agenti AI devono usare i server MCP di Google invece delle API REST. Un client che chiama solo le API REST "non è interessato". Da ricordare se le funzioni AI (oggi spente, DEC-011) dovessero un giorno toccare il calendario.

---

## 2. Sincronizzazione

### 2.1 Sincronizzazione incrementale

- La prima lettura completa di una raccolta restituisce, sull'ultima pagina, un `nextSyncToken`. Le letture successive con quel token danno solo ciò che è cambiato, cancellazioni comprese.
- Hanno il token: eventi (per calendario), elenco dei calendari, impostazioni, permessi di condivisione.
- Con il token non si possono usare `timeMin`, `timeMax`, `q`, `orderBy`, `iCalUID`, `updatedMin`.
- Il server può invalidare il token (scadenza, cambi di permessi): risponde 410 e il client deve **svuotare la copia locale e rifare la lettura completa**. La durata del token non è pubblicata.
- La prima lettura si può limitare nel tempo: l'esempio di Google usa `timeMin` solo sulla prima richiesta ("only syncing events up to a year old"). Che cosa copra poi il token per gli eventi più vecchi non è documentato (non verificato).
- Pagina massima: 2.500 eventi. Richieste in batch: fino a 1.000 chiamate, che contano una per una sulla quota.

### 2.2 Push: perché no, e cosa fare invece

Google consegna le notifiche di cambiamento solo a un indirizzo HTTPS con certificato valido (non autofirmato). Il canale scade (7 giorni per impostazione predefinita) e non si rinnova da solo. Le notifiche non hanno corpo e "non sono affidabili al 100%": serve comunque una sincronizzazione periodica. La Workspace Events API (via Pub/Sub) copre Chat, Drive e Meet, **non Calendar**.

Un client desktop senza server ha tre strade:

| Strada | Giudizio |
|---|---|
| **Interrogare a intervalli con i token** | Raccomandata. È ciò che MishMail fa già per la posta (`PollCadence`: 60 s in primo piano, 180 s in secondo piano, 300 s in risparmio energetico). |
| Un piccolo server di inoltro | Scartata: contraddice "nessun server", porta dati personali fuori dal Mac e farebbe scattare l'assessment di sicurezza. |
| Usare l'arrivo di un'e-mail d'invito come segnale | Complemento gratuito: quando la sincronizzazione della posta vede un invito, si rilegge subito il calendario. |

### 2.3 Costo dell'interrogazione

Stima nostra: una `events.list` con token per ogni calendario seguito, più una per l'elenco dei calendari. Con 2 account e 5 calendari ciascuno, una volta al minuto, sono circa 12 richieste al minuto, contro 600 per utente. Una risposta senza cambiamenti è di poche centinaia di byte. Google sconsiglia l'interrogazione fitta per chi ha migliaia di utenti su un solo progetto, e chiede di variare gli intervalli regolari del ±25%: da applicare. Per il calendario basta un ritmo più lento della posta (per esempio ogni 5 minuti in secondo piano), più una lettura immediata quando la finestra torna in primo piano o l'utente apre il calendario.

### 2.4 Eventi ricorrenti

Per impostazione predefinita `events.list` restituisce la serie (una riga con la regola) e le sue eccezioni, non le singole occorrenze. Due modi:

| Modo | Pro | Contro |
|---|---|---|
| **A. Espansione da Google** (`singleEvents=true` su una finestra di date) | Nessun calcolo nostro di regole, fusi e ora legale. È ciò che #55 fa già per la disponibilità. | Una finestra di date non si combina con il token: ogni finestra va riletta per intero. Offline si vede solo ciò che è già stato letto. |
| **B. Espansione locale** (si conservano serie ed eccezioni, le occorrenze si calcolano) | Funziona offline per qualunque data; sincronizzazione solo incrementale. | Serve un motore RRULE corretto (BYDAY, BYSETPOS, EXDATE, UNTIL, ora legale, tutto il giorno). È il punto più facile da sbagliare dell'intero progetto. |

Proposta: per il pannello agenda, modo **ibrido**: il token dice *se* un calendario è cambiato; quando è cambiato si rilegge con `singleEvents=true` la finestra conservata (per esempio da −1 a +12 mesi). Il motore locale (modo B) si scrive solo con la finestra completa e le modifiche offline. L'esempio di Google usa `singleEvents=true` insieme al token, ma fin dove arrivi l'espansione di una serie senza fine non è documentato (non verificato): da provare prima di contarci.

### 2.5 Fusi orari ed eventi di tutto il giorno

- Un evento con orario è un istante più un fuso IANA; si mostra nel fuso del Mac, come Gmail. Le serie si espandono nel fuso della serie, non in quello di chi guarda.
- Un evento di tutto il giorno è una data senza fuso, con fine esclusa: non va mai convertito in un istante, altrimenti scivola di un giorno. #55 lo tratta già così per i conflitti (`CalendarSpan.localMidnight`).
- `Support/ICSTimeZone.swift` e `Support/WindowsTimeZones.swift` (inviti .ics) si riusano.

### 2.6 Modifiche offline e conflitti

- Ogni evento ha un `etag`. Una modifica inviata con `If-Match` fallisce con 412 se nel frattempo l'evento è cambiato; Google suggerisce di rileggere e riapplicare.
- Una creazione può portare un identificativo scelto dal client (base32hex, 5–1024 caratteri, consigliato un UUID): ripetere l'invio dopo un errore di rete non crea doppioni (409 se esiste già).
- Regola proposta, come Gmail e come la coda `pendingThreadOp` della posta: le modifiche offline entrano in una coda cifrata e partono al ritorno della rete. Su 412 **vince il server** per i campi toccati da entrambi e l'utente viene avvisato; nessuna fusione silenziosa. Per gli eventi con invitati, la modifica offline non manda nulla finché non è confermata da Google.
- Primo passo ragionevole: modifiche solo in linea, lettura anche offline. È già più di quanto offra il web.

### 2.7 Che cosa conterrebbe il database cifrato

| Dato | Note |
|---|---|
| Calendari seguiti, con colore, ruolo, fuso, promemoria predefiniti | Estende `calendarSource` (v61). |
| Token di sincronizzazione per calendario | Nuovo. La colonna `syncToken` fu tolta da #55 perché senza uso. |
| Eventi: titolo, luogo, descrizione, orari, regola, invitati e risposte, link di conferenza, promemoria, `etag` | Nuovo. Sono dati personali anche di terzi (indirizzi degli invitati). |
| Coda delle modifiche in attesa | Nuovo, solo con le modifiche offline. |
| Indice di ricerca degli eventi | Nuovo, solo con la ricerca offline. |

Dimensione, stima nostra non misurata: un evento occupa 1–2 KB; 5.000–15.000 eventi (alcuni calendari, finestra da −1 a +2 anni) fanno 10–30 MB. È poco rispetto alla posta (la sola cache delle immagini ha un tetto di 200 MiB).

Regole già decise che si applicano: tutto a cascata dall'account e cancellato con lui (DEC-013); cancellato vuol dire sparito, anche dall'indice (DEC-019); un 410 di Google impone comunque di svuotare e rileggere. Da decidere: quanto passato conservare (domanda 4).

---

## 3. EventKit e gli account di sistema al posto della Google API?

**Che cosa dà EventKit.** Lettura e scrittura degli eventi che macOS già sincronizza (iCloud, Exchange, Google via CalDAV), con regole di ricorrenza, eccezioni ("solo questo" o "questo e i futuri"; non esiste "tutti"), avvisi, luogo, colore del calendario. Un'unica notifica `EKEventStoreChanged` senza dettagli: a ogni cambiamento si rilegge tutto. Le ricerche coprono al massimo quattro anni.

**Permessi.** Da macOS 14: accesso completo (`requestFullAccessToEvents`, chiave `NSCalendarsFullAccessUsageDescription`) o sola scrittura; non esiste la sola lettura. L'app è in sandbox (`MishMail.Distribution.entitlements`): servirebbe anche l'entitlement `com.apple.security.personal-information.calendars`. L'accesso completo riguarda **tutti** i calendari del Mac, non solo quelli Google.

**Limiti verificati.**

- Gli invitati sono in sola lettura: "it is not possible to add attendees with Event Kit". Lo stato di partecipazione è in sola lettura: non si risponde a un invito.
- Nessuna API per creare un link Meet, per il libero/occupato di altre persone, per le sale (assenza constatata nel riferimento; un divieto esplicito non è scritto).
- Un'app non può aggiungere un account: `EKSource` non si crea. L'utente deve aggiungere l'account Google in Calendario o nelle Impostazioni di Sistema. Che questo passi da un consenso Google separato da quello di MishMail è l'esperienza comune ma non è scritto nelle pagine lette (non verificato).
- Le interfacce pronte di EventKitUI non esistono su macOS nativo (solo iOS e Mac Catalyst): le viste andrebbero scritte comunque.
- Ogni quanto macOS aggiorni un account Google, e se sincronizzi i Google Tasks in Promemoria: non verificato; serve una prova su un Mac.

**Che cosa si perderebbe rispetto a Gmail.** Invitare persone, rispondere dal calendario, Meet, trova un orario, sale, tipi di evento di Google (fuori sede, sede di lavoro), etichette e colori per evento come su Google, aggiornamento rapido, corrispondenza certa tra account di posta e calendario (in EventKit un calendario non dice a quale account MishMail appartiene). In più i dati starebbero nell'archivio di sistema, fuori dal database cifrato e dalle regole di cancellazione di MishMail.

**Giudizio.** EventKit non sostituisce la Google API per un calendario "come Gmail". Può servire come **aggiunta facoltativa, in sola lettura**: mostrare anche i calendari non Google del Mac (iCloud, Exchange) nella disponibilità e nell'agenda. Costa un permesso ampio e porta una seconda fonte di verità: da valutare solo se il proprietario lo chiede (domanda 8). "Open in Calendar" di oggi (apre l'.ics su gesto dell'utente) resta e non richiede permessi.

---

## 4. Come si innesta nel codice di oggi

### 4.1 Che cosa c'è già

Tutto dietro `MISHMAIL_CALENDAR`, spento per impostazione predefinita, e non ancora provato su un account reale (C-45).

| PR | Contenuto |
|---|---|
| #51 (v59) | Parser .ics come input non fidato (`Support/CalendarInvite.swift`), risposta per e-mail (iTIP REPLY), tabella cifrata `calendarRSVP` (`Store/CalendarRSVPStore.swift`). Vale anche con l'interruttore spento. |
| #55 (v61) | Interruttore di build (`CalendarFeatures`); secondo consenso separato con un suo token nel Keychain (`CalendarAuthorization`, `CalendarTokenSource`); client (`CalendarClient`): elenco calendari, eventi in una finestra con ricorrenze espanse da Google, eventi per UID, libero/occupato a gruppi di 50, risposta dell'utente, `events.import`; logica pura di conflitti e instradamento (`CalendarAvailability`, `CalendarInvitePlan`); tabelle `calendarGrant` e `calendarSource` (`CalendarStore`). |
| #57 | Unica porta dall'app verso la cartella Calendar (`CalendarIntegration`); riga "Google Calendar" per account in Settings → Accounts (`UI/CalendarAccountSettings.swift`); scheda dell'invito con disponibilità, "Add to Calendar" e risposta scritta anche sul calendario (`UI/CalendarInviteCard.swift`, `App/MailStore+CalendarAccess.swift`). |

### 4.2 Che cosa manca per un calendario completo

Nessun evento è conservato (solo permesso e calendari scelti); nessuna sincronizzazione (il codice fu tolto in #55 perché senza uso); nessuna vista; nessuna creazione o modifica (solo la propria risposta e l'import di un invito non ricorrente); nessun promemoria; nessuna lettura delle impostazioni; niente Meet, sale, trova un orario, ricerca, task; nessuna modifica offline; "Add to Calendar" punta sempre al calendario principale.

### 4.3 Che cosa si riusa e che cosa cambia

| Area | Si riusa | Cambia o si aggiunge |
|---|---|---|
| Account e permessi | `CalendarScope`, `CalendarGrant` (gestisce già un consenso parziale), `CalendarAccessState`, `CalendarAuthorization.request`, `OAuthService.authorize(scopes:loginHint:)`, chiave Keychain `calendarRefreshToken.<account>`. | Nuove capacità in `CalendarCapability` (impostazioni, gestione calendari, task). Ogni ambito nuovo passa da "Reconnect…": il flusso esiste. |
| Client | `CalendarClient`, `CalendarTransport` (rifiuta con l'interruttore spento), `CalendarError.classify`, pausa su `Retry-After`. | Metodi `insert`, `update` con `If-Match`, `delete`, lettura con token e gestione del 410, `settings.list`, `conferenceData`. I tipi `GCalendarEvent` e `GCalendarListEntry` crescono (colore, `etag`, `recurrence`, promemoria, `eventType`). |
| Archivio e migrazioni | `Store/Database.swift` (migrazioni fino a v64), `CalendarStore.createTables`, cascata da `account`, `CalendarStore.forget` e `purgeOrphans`, `AccountLifecycle.purgeAccount` e `purgeOrphanRows`. | Nuove tabelle con prefisso `calendar` (eventi, stato di sincronizzazione, più avanti coda e indice). Colonne nuove in `calendarSource`. La regola "nessun evento conservato" scritta in `CalendarStore.swift` e in `SECURITY.md` va sostituita, con decisione del proprietario. |
| Motore di sincronizzazione | I modelli, non il codice: `Gmail/SyncEngine.swift` è legato a `historyId` e ai thread. Si riusano `PollCadence`, `CoalescingRunner`, `ConnectivityMonitor`, `OfflinePolicy`, `AccessTokenCache`, `GoogleHTTP.session`, il timer in `App/MailStore+Sync.swift`. | Un motore Calendar a parte dentro `Sources/MishMail/Calendar/`, un attore per account come `SyncEngine`. La coda offline ricalca `pendingThreadOp` e `ThreadOpReplay`. |
| Notifiche | `Notifier`, `NotificationContent` (identificatori con l'account come hash salato, ritiro alla rimozione dell'account), impostazione per account "Show sender and subject in notifications" (DEC-056). | Un nuovo `NotificationContent.Kind` per i promemoria degli eventi. Testo generico per impostazione predefinita ("Event reminder", DEC-014); titolo e ora solo dove l'utente ha acceso i dettagli. Le notifiche si programmano in anticipo e vanno riprogrammate a ogni cambiamento e ritirate con l'evento (DEC-019). |
| Interruttore di build | `CalendarFeatures`, i controlli di `make install` e `make release`, `CalendarFeaturesTests` (nessuna riga fuori da `Calendar/` aggira l'interruttore). | Nulla. Finché il calendario non è deciso l'interruttore resta l'unico cancello; un'eventuale preferenza dell'utente si aggiunge sopra, non al suo posto. |
| Barra degli account | DEC-057 prevede in basso "Settings e, in futuro, altri collegamenti"; la barra è in lavorazione (PR #62). | Una voce "Calendar" in basso, visibile solo con l'interruttore acceso. Apre il pannello o la finestra (domanda 2). |
| Finestre | `MishMailApp.swift` ha un `WindowGroup` e `Settings`. | Per la finestra completa, una scena in più o una vista al posto della lista dei messaggi. |
| Più account | `MailStore.activeAccountId` (nil = tutti gli account), colore dell'account (DEC-025), anello (DEC-030). | Vista unificata: calendari di tutti gli account collegati, sovrapposti, ciascuno col suo colore come su Google. Un evento nuovo nasce sull'account attivo, o su quello del messaggio da cui parte. Un account senza Calendar collegato non mostra nulla e non chiede nulla. |
| Offline | Cache cifrata, `ConnectivityMonitor`, stato "Offline" già presente sulla scheda dell'invito. | Lettura offline dal primo passo; scrittura offline solo con la coda (sezione 2.6). |
| Inviti dalla posta | `CalendarInvite`, `CalendarInviteCard`, `CalendarRSVPStore`, DEC-049 e DEC-052. | Con gli eventi in locale la scheda legge dalla copia invece di chiedere a Google ogni volta. Una risposta data **dal calendario** non ha un messaggio a cui rispondere: va decisa (domanda 6). |

---

## 5. Opzioni, dalla più piccola alla più grande

Gli ordini di grandezza sono stime nostre, nello stesso metro del piano (che dà 4–6 settimane al perimetro C e oltre 6 al D). Senza un Mac in sviluppo ogni passo aggiunge prove manuali del proprietario.

| # | Opzione | Che cosa ottiene l'utente | Impegno | Rischi | Google deve approvare |
|---|---|---|---|---|---|
| 0 | **Ciò che c'è** (#55, #57), acceso | Disponibilità accanto all'invito, risposta anche sul calendario, "Add to Calendar". | Giorni: solo la prova C-45. | Doppia notifica all'organizzatore se `sendUpdates=none` non basta (non verificato). | Nulla col proprio client. |
| 1 | **Pannello agenda** in sola lettura | Il giorno (o i prossimi giorni) accanto alla posta, come il pannello di Gmail; tutti i calendari coi loro colori; funziona offline. | Settimane (4–6, perimetro C del piano). | Primo dato personale del calendario in locale; correttezza di fusi e giornate intere. | Nulla di nuovo: bastano gli ambiti di oggi. |
| 2 | **Promemoria** | Notifica prima dell'evento, secondo i promemoria impostati su Google. | 1–2 settimane sopra il passo 1. | Notifiche fuori dal database cifrato (per questo generiche); promemoria doppi se l'utente ha anche Calendar aperto altrove. | Nulla. |
| 3 | **Creare e modificare eventi semplici** | Nuovo evento dal pannello o da un messaggio (perimetro D), invitati, link Meet, cancellazione; solo in linea. | Settimane (6–8). | Scritture sui calendari veri: un errore manda inviti a persone reali. Modifica delle serie limitata a "solo questo" e "tutti". | Nulla di nuovo. |
| 4 | **Finestra calendario completa** | Giorno, settimana, mese, agenda; trascinamento; ricorrenze complete con "questo e i successivi"; scelta dei calendari; trova un orario; ricerca; modifiche offline. | Mesi (3–5). | Motore delle ricorrenze locale; molta interfaccia nuova; conflitti di modifica; manutenzione continua rispetto a Google. | Un nuovo consenso se si aggiungono `calendar.settings.readonly` o `calendar.calendarlist`. |
| 5 | **Task** | Elenchi e task di Google, con scadenza a giorno. | Settimane (3–4). | L'orario del task non è nell'API: non potrà essere come sul web. Ambito nuovo, classe non verificata. | Un nuovo consenso (`tasks`). |

Fuori portata per qualunque opzione: agende di appuntamenti, "proponi un nuovo orario" via API, Time Insights, elenco delle sale senza permessi da amministratore (non verificato), suggerimenti automatici di orario.

**Percorso raccomandato:** 0 → 1 → 2 → 3 → 4 → 5, fermandosi dove basta.

Motivi:

- ogni passo si regge sul precedente (la copia locale del passo 1 serve a promemoria, modifica e finestra) e ha valore da solo;
- i passi 0–3 non chiedono a Google niente oltre il consenso già deciso (DEC-048);
- il rischio cresce per gradi: prima solo lettura, poi notifiche, poi scritture in linea, e solo alla fine motore delle ricorrenze e coda offline;
- dopo il passo 3 MishMail offre già ciò che offre il pannello Calendar di Gmail. Il passo 4 è un prodotto a sé: va deciso guardando quanto il pannello viene usato.

---

## 6. Che cosa fare adesso

**Da fare (costa poco).**

1. **Tenere il confine.** Tutto ciò che è Calendar resta in `Sources/MishMail/Calendar/` e passa da `CalendarIntegration`; i test di `CalendarFeaturesTests` che lo impongono restano.
2. **Barra degli account (PR #62).** La parte bassa sia un elenco di voci, non un singolo pulsante Settings cablato: aggiungere "Calendar" o "Chat" deve essere una riga in più. Nessuna icona Calendar ora.
3. **Barra laterale e disposizione (PR #63).** Non dare per scontato che la finestra abbia sempre e solo tre colonne: il pannello di Gmail vive sul bordo destro, dove oggi c'è già il pannello AI (`AskMishPanelView`, spento). Uno "spazio del pannello destro" unico evita di rifare la disposizione.
4. **Nomi nell'archivio.** Le nuove tabelle della posta non usino il prefisso `calendar`. Ogni tabella per account continui a entrare in `AccountLifecycle.purgeAccount` e `purgeOrphanRows`: è ciò che renderà gratuita la cancellazione degli eventi.
5. **Notifiche.** Gli identificatori restino "tipo / account / chiave" con chiave libera, come ora: un promemoria di evento ci entra senza modifiche.
6. **Verifica OAuth.** Se un giorno si chiede a Google la verifica del client Gmail, decidere prima se includere gli ambiti Calendar: aggiungerli dopo vuol dire una seconda verifica.
7. **Prova C-45.** L'esito su `sendUpdates=none` e sul consenso reale è l'unica informazione mancante che cambia il disegno dei passi successivi.

**Da non fare.**

- Non unire gli ambiti Calendar all'accesso Gmail: un solo token renderebbe impossibile scollegare Calendar senza toccare la posta.
- Non chiedere l'ambito pieno `calendar` "per sicurezza": Google chiede l'ambito più stretto, e DEC-048 è già la scelta larga.
- Non conservare eventi adesso, nemmeno come cache: cambia ciò che `SECURITY.md` dichiara.
- Non aggiungere ora l'entitlement o la chiave di EventKit: farebbe comparire una richiesta di permesso per una funzione che non c'è.
- Non scrivere ora un motore di ricorrenze né una libreria per farlo: serve solo al passo 4.
- Non costruire un server di inoltro per le notifiche push.
- Non contare sulla modalità OAuth *Personal* per l'uso con più account: vale per un solo account.

---

## 7. Domande aperte per il proprietario

1. **Fin dove?** Basta il pannello come in Gmail (passi 1–3) o l'obiettivo è la finestra completa (passo 4)?
2. **Dove vive il calendario?** Pannello a destra della posta come Gmail, finestra separata, o vista al posto della lista dei messaggi? La voce nella barra degli account apre quale delle tre?
3. **Eventi in locale.** Va bene conservare nel database cifrato titoli, luoghi, descrizioni e indirizzi degli invitati? Oggi la regola scritta è "nessun evento conservato".
4. **Quanto passato?** Proposta: 1 anno indietro, 2 avanti. In alternativa tutto, o la stessa finestra della posta.
5. **Promemoria.** Li vuole MishMail, sapendo che chi tiene aperto anche Google Calendar li riceverà due volte? Generici per impostazione predefinita come la posta (DEC-014), con i dettagli legati alla stessa impostazione per account?
6. **Risposta data dal calendario.** DEC-049 dice "sempre calendario più e-mail". Per una risposta data dalla vista calendario, senza un messaggio aperto: si lascia che Google avvisi l'organizzatore (come fa Google Calendar), o MishMail manda comunque la sua e-mail?
7. **Calendari e impostazioni.** Colori e calendari visibili seguono Google e si riscrivono su Google (serve `calendar.calendarlist`, nuovo consenso), o sono scelte locali come il colore delle label (DEC-023)? Inizio settimana e formato dell'ora da Google (`calendar.settings.readonly`) o da macOS?
8. **Calendari non Google.** Interessa vedere anche iCloud o Exchange tramite EventKit, in sola lettura, al prezzo del permesso di macOS su tutti i calendari? O MishMail resta solo Google anche qui (DEC-002)?
9. **Task.** Servono, sapendo che l'orario non è disponibile e che richiedono un altro consenso?
10. **Distribuzione.** Resta "ognuno porta il proprio client OAuth"? Se si passa a un client condiviso, la verifica di Google va messa in conto prima di promettere il calendario ad altri.
11. **Interruttore.** Quando il calendario sarà pronto, resta un interruttore di build o diventa un'impostazione dell'utente, spenta per impostazione predefinita?

---

## 8. Che cosa non è stato verificato

- Tutto ciò che richiede un Mac e un account reale: il consenso, `sendUpdates=none`, l'import con un UID già esistente (C-45).
- La classe (sensitive o no) dei singoli ambiti Calendar e Tasks: si legge solo nella Cloud Console.
- Il comportamento di `singleEvents=true` con il token su serie senza fine, e che cosa copra il token dopo una prima lettura limitata da `timeMin`.
- Il procedimento ufficiale per "questo e i successivi".
- Se un utente non amministratore possa elencare le sale del dominio.
- Viste e funzioni esatte del pannello Calendar di Gmail (la guida non le elenca).
- Per macOS: ogni quanto si aggiorna un account Google, se i Google Tasks arrivano in Promemoria, se esista un limite al numero di notifiche locali programmate.
- Il prezzo per richiesta del livello Scaled delle quote (non serve sul livello Standard).
- Che le app desktop non possano estendere un consenso esistente: è riportato dal corpo della PR #55, non riletto oggi.
- Le stime di impegno, dimensione e traffico sono nostre, non misurate.

## 9. Fonti

Lette il 25 novembre 2026.

Google — Calendar API:

- Ambiti: https://developers.google.com/workspace/calendar/api/auth
- Quote e livelli: https://developers.google.com/workspace/calendar/api/guides/quota
- Note di rilascio: https://developers.google.com/workspace/calendar/release-notes
- Sincronizzazione: https://developers.google.com/workspace/calendar/api/guides/sync
- Notifiche push: https://developers.google.com/workspace/calendar/api/guides/push
- Eventi ricorrenti: https://developers.google.com/workspace/calendar/api/guides/recurringevents
- Versioni ed `etag`: https://developers.google.com/workspace/calendar/api/guides/version-resources
- Errori: https://developers.google.com/workspace/calendar/api/guides/errors
- Batch: https://developers.google.com/workspace/calendar/api/guides/batch
- Tipi di evento: https://developers.google.com/workspace/calendar/api/guides/event-types
- Stato (fuori sede, sede di lavoro): https://developers.google.com/workspace/calendar/api/guides/calendar-status
- Concetti (eventi e calendari, promemoria, condivisione, risorse del dominio): https://developers.google.com/workspace/calendar/api/concepts/events-calendars, https://developers.google.com/workspace/calendar/api/concepts/reminders, https://developers.google.com/workspace/calendar/api/concepts/sharing, https://developers.google.com/workspace/calendar/api/concepts/domain
- Riferimento: https://developers.google.com/workspace/calendar/api/v3/reference (Events, `events/list`, `events/insert`, `events/patch`, `events/watch`, CalendarList, Calendars, Acl, Settings, `freebusy/query`)

Google — altre API:

- Tasks, ambiti: https://developers.google.com/workspace/tasks/auth
- Tasks, riferimento: https://developers.google.com/workspace/tasks/reference/rest/v1/tasks
- Tasks, limiti: https://developers.google.com/workspace/tasks/limits
- Meet, ambiti e classe: https://developers.google.com/workspace/meet/api/guides/authenticate-authorize
- Workspace Events API: https://developers.google.com/workspace/events
- Admin SDK, risorse: https://developers.google.com/workspace/admin/directory/reference/rest/v1/resources.calendars/list

Google — OAuth e verifica:

- Categorie di ambiti: https://support.google.com/cloud/answer/13463073
- Ambiti restricted: https://support.google.com/cloud/answer/13464325
- Requisiti di verifica: https://support.google.com/cloud/answer/13464321
- Tempi e assessment: https://support.google.com/cloud/answer/13463817
- Aggiunta di ambiti: https://support.google.com/cloud/answer/13464018
- Tipi di utente, Testing, tetto di 100 utenti, modalità Personal: https://support.google.com/cloud/answer/15549945
- Ambiti sensibili: https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification
- Ambiti restricted: https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification

Google — guida per gli utenti:

- Pannello laterale: https://support.google.com/calendar/answer/106237
- Viste: https://support.google.com/calendar/answer/6110849
- Trova un orario: https://support.google.com/calendar/answer/6294878
- Proporre un nuovo orario: https://support.google.com/calendar/answer/37135
- Agende di appuntamenti: https://support.google.com/calendar/answer/10729749
- Orario di lavoro e fuori sede: https://support.google.com/calendar/answer/7638168
- Task in Calendar: https://support.google.com/calendar/answer/9901136
- Ricerca: https://support.google.com/calendar/answer/37176
- Offline: https://support.google.com/calendar/answer/1340696
- Eventi da Gmail: https://support.google.com/calendar/answer/6084018

Apple:

- Accesso all'archivio: https://developer.apple.com/documentation/eventkit/accessing-the-event-store
- TN3152 e TN3153: https://developer.apple.com/documentation/technotes/tn3152-migrating-to-the-latest-calendar-access-levels, https://developer.apple.com/documentation/technotes/tn3153-adopting-api-changes-for-eventkit-in-ios-macos-and-watchos
- Entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.calendars
- `EKSource`, `EKSourceType`, `EKEventStore`: https://developer.apple.com/documentation/eventkit/eksource, https://developer.apple.com/documentation/eventkit/eksourcetype, https://developer.apple.com/documentation/eventkit/ekeventstore
- Invitati: https://developer.apple.com/documentation/eventkit/ekcalendaritem/attendees, https://developer.apple.com/documentation/eventkit/ekparticipant
- Ricorrenze: https://developer.apple.com/documentation/eventkit/ekrecurrencerule, https://developer.apple.com/documentation/eventkit/ekspan
- Limite di quattro anni: https://developer.apple.com/documentation/eventkit/ekeventstore/predicateforevents(withstart:end:calendars:)
- EventKitUI: https://developer.apple.com/documentation/eventkitui
- Account in Calendario: https://support.apple.com/guide/calendar/add-calendars-and-calendar-accounts-icl4308d6701/mac

Repository: PR #51, #55, #57; `docs/registro-decisioni.md` (DEC-002, 013, 014, 019, 023, 042, 046, 048, 049, 052, 056, 057); `docs/piano-sviluppo.md` (ondata 4, C-45).
