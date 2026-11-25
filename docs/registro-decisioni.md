# Client Gmail per macOS — Registro delle decisioni

Versione: 0.22
Ultimo aggiornamento: 25 novembre 2026
Stato: documento in evoluzione

## 1. Obiettivo

Sviluppare un client e-mail desktop per macOS, dedicato esclusivamente agli account Gmail, capace di riprodurre il più fedelmente possibile l'esperienza di Gmail con un'interfaccia e un comportamento nativi per macOS.

## 2. Decisioni confermate

| ID | Decisione | Motivazione |
|---|---|---|
| DEC-001 | **Solo macOS** | Non è più richiesta la compatibilità con Windows e Linux. |
| DEC-002 | **Solo account Gmail** | Non è necessario supportare provider IMAP generici. |
| DEC-003 | **Gmail API anziché IMAP/SMTP** | Accesso diretto a thread, label, loro colori, filtri e cronologia delle modifiche di Gmail. |
| DEC-004 | **Sviluppo ed esecuzione fuori dal Mac App Store** | È possibile avviare l'app con Xcode e utilizzarla localmente come `.app`. |
| DEC-005 | **Accesso con Google e sessione persistente** | OAuth 2.0 con refresh token; evitare autenticazioni ripetute durante lo sviluppo. |
| DEC-006 | **Linguaggio non vincolante** | La tecnologia viene scelta in funzione dell'obiettivo e della piattaforma. |
| DEC-007 | **Approccio fork + riuso selettivo** | Usare **MishMail come candidato principale per il fork** e **Postie come fonte di funzionalità e test**. Decisione di indirizzo, subordinata all'audit dei repository e alla compilazione delle due applicazioni. Dalla v0.7 il ruolo di Postie è ridimensionato: ICS/RSVP esiste già nel fork (sezione 8.2). |
| DEC-008 | **Security-first prima di importare funzionalità** | Risolvere i rischi prioritari dell'audit sul fork; effettuare test nativi macOS prima di collegare account reali o distribuire build. |
| DEC-009 | **Aggiornamenti automatici sospesi nel fork di sviluppo** | Disabilitare la sostituzione automatica di eseguibili finché non siano definiti canale di release, identità del publisher e controlli anti-rollback. Dalla v0.7 è un prerequisito per l'uso con account reali, non solo per la distribuzione: l'updater parte da solo anche sulle build locali (sezione 13). Implementato nello step 1A (PR #7): updater inerte senza canale e comunque spento su una copia senza Team ID. |
| DEC-010 | **GO su MishMail come base** | Decisione del 23 novembre 2026, dopo la CI verde sul commit auditato. Postie resta un riferimento di confronto. |
| DEC-011 | **AI e server MCP spenti per il momento** | Estranei all'obiettivo della sezione 1 e sede di quattro finding. Il codice resta; un'impostazione di build li riaccende (`MISHMAIL_AI_FEATURES`, step 2A). |
| DEC-012 | **Notion Mail fuori dal prodotto** | Non interessa: rimossi la funzione di migrazione e ogni riferimento (PR #11). |
| DEC-013 | **La rimozione di un account cancella sempre tutto ciò che gli appartiene** | Nessuna richiesta su cosa conservare: più semplice e più sicuro (step 2B). |
| DEC-014 | **Notifiche generiche come impostazione predefinita** | "New mail" senza mittente né oggetto; mittente e oggetto solo se attivati dall'utente (step 2B). |
| DEC-015 | **Messaggio d'errore di Gmail limitato a 160 caratteri** | L'avviso mantiene il messaggio leggibile di Google, accettando che possa riportare parte della richiesta, per esempio una ricerca; il JSON grezzo e gli altri campi restano fuori (PR #10). |
| DEC-016 | **F-01 segnalato all'upstream dal proprietario** | La segnalazione riservata secondo `SECURITY.md` è a carico del proprietario del fork. |
| DEC-017 | **Shortcut predefiniti come Gmail Web** | I tasti predefiniti seguono Gmail sul web e restano personalizzabili; dove Gmail confligge con una convenzione di macOS vince macOS (PR #17). |
| DEC-018 | **Apertura nel pannello di lettura come predefinito** | In Settings → Appearance → "Opening a conversation" il predefinito è "Shows in a reading pane"; una scelta salvata viene rispettata (PR #17). |
| DEC-019 | **Cancellato vuol dire sparito** | Ciò che viene cancellato non deve più esistere, non solo risultare irraggiungibile: sovrascrittura nel database e nell'indice di ricerca, pulizia del file di appoggio, rimozione di allegati e notifiche con il messaggio. I limiti fisici (SSD, backup, istantanee) sono dichiarati in `SECURITY.md` (PR #18). |
| DEC-020 | **Chat AI alla rimozione di un account: regola prudente** | Rimuovere un account cancella ogni chat che ha usato uno strumento e tutte quelle prive di tracciatura. Confermato dal proprietario. |
| DEC-021 | **Icone monocromatiche** | Le icone di navigazione (barra laterale, impostazioni, intestazione della lista) sono in scala di grigi come in Gmail; il colore resta solo dove porta informazione: colori delle label, stella, badge, avvisi (PR #20). |
| DEC-022 | **Correttore in più lingue insieme** | Si usano i dizionari di macOS, senza cambiare impostazioni di sistema. Con più lingue scelte una parola è sottolineata solo se sbagliata in tutte; il costo accettato è che un refuso valido in un'altra lingua scelta non viene segnalato (PR #22). |
| DEC-023 | **Colori delle label come in Gmail** | Il colore di una label è quello di Gmail, aggiornato a ogni sincronizzazione; fondo pieno e testo sempre leggibile. Un colore scelto nell'app ha la precedenza e non viene scritto su Gmail. Le label senza colore sono grigio neutro (PR #25). |
| DEC-024 | **Stile di comunicazione conciso** | Tutte le sessioni di lavoro sul repository comunicano in modo conciso, secondo `CLAUDE.md`; errori, passi saltati e cose non verificate si dichiarano sempre (PR #24). |
| DEC-025 | **Colore della label dell'account** | Ogni account ha un colore locale per la sua label, scelto con il selettore di colore di sistema; non viene inviato a Google e viene cancellato con l'account (PR #31). |
| DEC-026 | **Foto profilo Google** | L'avatar dell'account è la foto profilo Google, ottenuta senza nuovi permessi, scaricata solo da host Google senza token, conservata nel database cifrato e cancellata con l'account (PR #32). |
| DEC-027 | **Warning come errori in CI** | La CI fallisce su qualsiasi warning di compilazione nel codice dell'app e dei test di unità, ed esegue i test degli script e `shellcheck`; le build locali e di rilascio non cambiano (PR #33). |
| DEC-028 | **Icone della barra laterale** | Le icone seguono la dimensione della barra laterale impostata in macOS e non usano mai il colore d'accento (PR #34). La questione della capsula di selezione standard, rimasta in attesa di conferma, è superata da DEC-035: il proprietario ha chiesto un colore d'accento configurabile. |
| DEC-029 | **Forma delle label come in Gmail** | Le label sono rettangoli arrotondati compatti nel colore della label, senza contorno sulle righe normali; il contorno resta solo per colori quasi invisibili sullo sfondo, sulla selezione quando la label vi si confonderebbe e sui pallini di colore. Le label senza colore sono grigio neutro (PR #37). |
| DEC-030 | **Colore dell'account come anello, label come titolo** | Il colore della label dell'account è un anello intorno alla foto (spessore 3 pt, raddoppiato su richiesta) e il nome della label sostituisce il nome del mittente come titolo dell'account; la pillola dell'account è rimossa. Nei punti visibili ai destinatari resta il nome del mittente (PR #36, #41). |
| DEC-031 | **Messaggi di un thread come in Gmail** | Nel pannello di lettura i messaggi di una conversazione sono righe piatte a tutta larghezza separate da un filetto, non schede (PR #38). |
| DEC-032 | **Cache persistente e cifrata delle immagini incorporate** | "Sì, è necessaria": le immagini incorporate (`cid:`) già risolte restano nel database cifrato tra un avvio e l'altro, entro 200 MiB, e spariscono con messaggio, thread e account secondo DEC-019 (PR #39, migrazione v54). |
| DEC-033 | **Immagini remote caricate per impostazione predefinita** | Il predefinito di "Load remote images" è caricarle, con due limiti approvati: si caricano solo all'apertura del messaggio, mai in anticipo per i vicini, e la posta in Spam resta bloccata. Una scelta salvata viene rispettata; "Ask each time" e "VIP senders" restano disponibili. Costo accettato: il mittente apprende apertura, indirizzo IP e client (PR #40). |
| DEC-034 | **Cache delle immagini remote solo dove sono già permesse** | Le immagini remote entrano nella cache cifrata solo per i messaggi in cui il caricamento è già consentito; stesse regole di cancellazione di DEC-019 e DEC-032 (PR #42, migrazione v55, in lavorazione). |
| DEC-035 | **Colore d'accento configurabile** | Il colore d'accento dell'app si sceglie con il selettore di colore di sistema in Settings → Appearance; "Default" mantiene l'aspetto precedente. Il testo sull'accento resta leggibile (bianco o nero); la riga selezionata nel colore scelto vale solo su macOS 26 e successivi (PR #43). Supera la questione lasciata aperta in DEC-028. |
| DEC-036 | **Modifiche semplici senza review** | Quando il proprietario qualifica una richiesta come semplice, la esegue una sessione Sonnet, senza `ponytail-review` né `security-audit`, e la PR si unisce in `main` a CI verde. La scorciatoia non si applica per iniziativa dell'orchestratore (prima applicazione: PR #41). |
| DEC-037 | **Processo: archiviazione, branch, subentro** | Una sessione che ha finito senza nulla di pendente viene archiviata subito dall'orchestratore; non si chiede di cancellare i branch, che GitHub elimina all'unione. Il 24 novembre 2026 il proprietario ha sostituito l'orchestratore con una nuova sessione, a cui sono state passate tutte le istruzioni di processo. |
| DEC-038 | **Livelli di review** | Tre livelli, scritti in `CLAUDE.md`: modifica semplice (una proprietà, un colore): Sonnet, nessuna review, unione diretta in `main` senza attendere la CI; lavoro non complesso e a basso rischio di sicurezza: Sonnet, solo `ponytail-review`, PR regolare; tutto il resto: Opus con entrambe le review. `ponytail-review` gira in modalità `full`, non più `ultra`. Sostituisce DEC-036 (PR #46). |
| DEC-039 | **Segnalazione di F-01 all'upstream annullata** | Il proprietario ha tolto il compito: F-01 non viene segnalato all'upstream. Nel fork resta mitigato con l'updater spento (DEC-009). Sostituisce DEC-016. |
| DEC-040 | **Ondata 3 avviata** | Avviata dal proprietario il 25 novembre 2026 senza attendere il completamento del cancello; le verifiche su Mac e su account reale restano da fare PR per PR. |
| DEC-041 | **Snooze: variante B** | Il modello resta quello locale (conversazione archiviata su Gmail e risvegliata da MishMail aperto), reso corretto; in più le conversazioni posticipate su Gmail da web o telefono compaiono in "Snoozed" anche sul Mac, senza orario. Alla rimozione di un account le conversazioni posticipate da MishMail tornano in Inbox prima della cancellazione (PR #47). |
| DEC-042 | **Google Calendar: perimetro B** | Disponibilità accanto all'invito, risposta scritta sul calendario, "aggiungi al calendario", con un secondo consenso Google separato. Agenda, promemoria ed eventi da un messaggio (perimetri C e D) restano lavoro futuro. |
| DEC-043 | **Immagini remote: prima apertura come oggi** | Alla prima apertura le immagini si caricano dal vivo e l'app le salva in secondo piano per le aperture successive; costo accettato: due richieste al mittente alla prima apertura. La variante a richiesta singola resta un seguito (PR #42). |
| DEC-044 | **Ondata 4 avviata** | Avviata dal proprietario il 25 novembre 2026 in parallelo all'ondata 3. |
| DEC-045 | **PGP: perimetro B** | Verifica delle firme, decifratura e import manuale delle chiavi. Invio firmato o cifrato, generazione di chiavi, ricerca di chiavi in rete e Autocrypt (perimetri C e D) restano lavoro futuro. La libreria crittografica si adotta solo con il sì esplicito del proprietario. |
| DEC-046 | **Calendari per i conflitti scelti dall'utente** | Per ogni account l'utente sceglie quali calendari contano per disponibilità e conflitti; il principale è selezionato per impostazione predefinita. |
| DEC-047 | **Libreria OpenPGP: rPGP (Rust), se non esiste una soluzione già pronta** | Sì a rPGP, a condizione che la sessione verifichi prima che non esista una soluzione già pronta all'uso (ad esempio una libreria in Swift). Se ne esiste una adeguata, decide il proprietario. Motivo della preferenza per Rust rispetto a Go: nessun runtime nell'app e chiavi azzerabili in memoria. GnuPG scartato: programma esterno, incompatibile con la sandbox e con "cancellato vuol dire sparito". |
| DEC-048 | **Calendar: permesso ampio** | A Google si chiede `calendar.events`: lettura e scrittura sugli eventi di tutti i calendari, condivisi inclusi, così i conflitti mostrano anche i titoli dei calendari condivisi. Scartata l'alternativa stretta (solo eventi propri più libero/occupato). |
| DEC-049 | **Risposta agli inviti: sempre calendario più e-mail** | Con Calendar collegato la risposta va sul calendario (senza notifiche di Google) e sempre anche per e-mail all'organizzatore. Sostituisce la regola "solo calendario per gli organizzatori Google": i segnali per riconoscerli sono scritti dal mittente e un invito falsificato sarebbe risultato accettato senza avvisare l'organizzatore. Decisione dell'orchestratore dopo le review della PR #55, comunicata al proprietario, ribaltabile dopo la prova con account reali. |
| DEC-050 | **Libreria OpenPGP in un repository separato** | La libreria rPGP compilata sta nel repository `bateman/dreamail-openpgp`, creato dal proprietario; MishMail la fissa per versione e checksum come già fa con GRDB. Scartata la compilazione in CI da `Vendor/`, che avrebbe richiesto di modificare il controllo `check-package-pins`. La verifica delle alternative richiesta da DEC-047 è fatta: nessuna soluzione Swift o Objective-C pronta è adeguata (tabella con le fonti nella PR #56). |
| DEC-051 | **OpenPGP: chiavi Ed448/X448 rifiutate** | Chiavi, firme e messaggi Ed448/X448 risultano "non supportati": la dipendenza che li implementa (`cx448`) si dichiara non verificata e non pubblica un testo di licenza, e non si può togliere dalla compilazione di rPGP 0.21.1. Rifiutati anche MD5, RIPEMD-160 e SHA-1 nelle firme dei messaggi. Due avvisi sui tempi di calcolo (RUSTSEC-2023-0071 su `rsa`, RUSTSEC-2026-0387 su `crypto-bigint`) sono accettati come limiti noti, senza correzione disponibile per rPGP 0.21.1. Decisione dell'orchestratore, comunicata al proprietario, ribaltabile. |
| DEC-052 | **Risposta agli inviti: prima l'e-mail, poi il calendario** | Con Calendar collegato l'e-mail di risposta parte per prima; il calendario viene scritto solo dopo, e un suo errore produce solo un avviso. Precisa DEC-049. |
| DEC-053 | **Badge dei non letti sulla foto profilo** | Ogni foto profilo nel selettore degli account mostra i non letti del suo account, nell'angolo in alto a destra, anche sopra l'anello colorato; stesso criterio del badge del Dock; tetto "99+"; nessun badge sulla voce "tutti gli account". |
| DEC-054 | **Nel dubbio, come fa Gmail** | Quando una richiesta lascia aperta una scelta e serve un'assunzione, si prende il comportamento di Gmail (prima il web) e la si dichiara nel messaggio che avvia il lavoro, senza fermarsi a chiedere. Le decisioni già registrate che si scostano da Gmail di proposito restano valide. Regola scritta anche in `CLAUDE.md`. |
| DEC-055 | **Firme per account** | Più firme con nome per account, una predefinita per i nuovi messaggi e una per risposte e inoltri; nel database cifrato, cancellate con l'account; "Importa da Gmail" copia la firma di Gmail senza riscriverla su Gmail; in composizione la firma del mittente entra da sola, segue il cambio di mittente se non è stata modificata a mano, e si sceglie da un menu che include "Nessuna firma". |
| DEC-056 | **Impostazioni per account** | "Show sender and subject in notifications" diventa un'impostazione di ciascun account: gli account esistenti ereditano il valore globale, i nuovi partono spenti (DEC-014). I filtri Gmail si vedono e si modificano per account. |
| DEC-057 | **Barra laterale come Gmail e barra degli account** | La barra laterale segue Gmail: viste di sistema nel suo ordine, riga "More", sezione "Labels" con le label ad albero; ciò che è solo di MishMail (Reminders, Outbox, viste salvate) trova posto sotto "More" o in una sezione "Views". A sinistra una barra degli account sempre visibile, di colore fisso (non l'accent) diverso in modalità chiara e scura, con le foto profilo e i non letti per account; in basso Settings e, in futuro, altri collegamenti. |
| DEC-058 | **`make run` con l'account reale** | `DEMO=0` è il predefinito; la casella finta resta per i test di interfaccia e per chi la chiede con `DEMO=1`. Il codice del demo non viene tolto. |
| DEC-059 | **Rilasci della libreria OpenPGP** | Il workflow "Release" di `bateman/dreamail-openpgp` può essere lanciato dall'orchestratore. La libreria si compila senza LTO, perché gli oggetti in bitcode di Rust non sono leggibili da Xcode. |
| DEC-060 | **Libreria OpenPGP collegata anche a interruttore spento** | Con `MISHMAIL_PGP` spento la libreria resta collegata nell'app e la tabella delle chiavi esiste vuota; il comportamento non cambia e nessuna voce PGP è visibile. Dopo la verifica del funzionamento si valuta il caricamento dinamico, con un'opzione che da spenta non carica la libreria. |
| DEC-061 | **Nomi del rebranding a DreaMail** | Decisi i nomi, non ancora la data: MishMail → DreaMail (D e M maiuscole; `dreamail` in percorsi e URL, `DREAMAIL_` per interruttori e variabili), prefisso C `mm_` → `dm_`, libreria `MishMailRPGP` → `DreaMailRPGP`, "Ask Mish" → "Ask AI". Le funzioni AI e MCP restano nel codice, spente (DEC-011): serviranno per il completamento delle e-mail e la riscrittura delle bozze. Studio in `docs/studi/rebranding-dreamail.md`. |
| DEC-062 | **Chat e Calendar integrati: solo studio per ora** | Chat di Gmail e Google Calendar completo non si costruiscono finché il client di posta non è completo e stabile per l'uso quotidiano. Studi in `docs/studi/google-chat.md` e `docs/studi/google-calendar.md`. |
| DEC-063 | **Barra laterale come Gmail: scostamenti** | Spam mostra solo ciò che il Mac ha (spam arrivato dopo l'aggiunta dell'account o segnalato dall'app): lo spam più vecchio resta su Gmail. La vista di tutte le etichette esce dalla barra laterale e resta su `g l`, Go ▸ Labels e palette. "Purchases" di Gmail non è offerta: l'API non ha quell'etichetta. Outbox e Reminders restano visibili fuori da "More" quando non sono vuoti. |

## 3. Stack (verificato nel fork al commit `18294fa`, salvo dove indicato)

| Ambito | Scelta | Stato |
|---|---|---|
| Linguaggio | Swift 5.10; target macOS 14.0; Xcode 15.3+ | Verificato in `project.yml` |
| Progetto Xcode | Generato con `xcodegen` da `project.yml`; build tramite `Makefile` | Verificato |
| Interfaccia | SwiftUI del fork MishMail, con AppKit dove necessario | Indirizzo confermato; dettagli da validare |
| API e-mail | Gmail REST API | Confermato |
| Calendario | Google Calendar API (assente nel fork) + parser ICS (già presente) | Proposto |
| Autenticazione | OAuth 2.0 Authorization Code + PKCE S256, client Google di tipo "Desktop app" portato dall'utente | Verificato in `Auth/OAuth.swift` |
| Login macOS | Browser di sistema + listener loopback su `127.0.0.1`. La proposta `ASWebAuthenticationSession` della v0.6 è ritirata: sostituirebbe un flusso funzionante senza beneficio dimostrato (regola della sezione 8.2). | Verificato |
| Segreti | macOS Keychain per refresh token e client secret | Verificato; ACL da provare su macOS |
| Persistenza | SQLite/FTS5 tramite GRDB 3.0.0 del fork DuckDuckGo (`duckduckgo/GRDB.swift`) con SQLCipher | Verificato in `project.yml`; cifratura effettiva da provare su macOS |
| Contenuti HTML | `WKWebView` con protezioni per contenuti remoti (già presenti, sezione 12.4) | Verificato in sorgente |
| PGP | Libreria OpenPGP consolidata; integrazione da valutare | Da valutare |
| Distribuzione | Build locale Xcode; firma/notarizzazione solo se distribuita a terzi | Confermato per la fase iniziale |

## 4. Requisiti funzionali

La colonna "Stato nel fork" riporta ciò che il codice contiene al commit `18294fa`. È una lettura del sorgente, non una prova d'uso: ogni voce "presente" va confermata con l'app in esecuzione.

| Funzionalità | Approccio previsto | Stato nel fork | Stato requisito |
|---|---|---|---|
| Lettura, scrittura e ricerca | Gmail API | Presente | Richiesto |
| Scorciatoie in stile Gmail | Command system configurabile nell'app | Presente: tasti singoli riconfigurabili (`Support/KeyBindings.swift`) e command palette; copertura rispetto a Gmail da verificare | Richiesto |
| Label multiple e colori | Gmail API; label native di Gmail | Parziale: label e colori sincronizzati (`Gmail/SyncEngine.swift`), creazione label presente; modifica dei colori da verificare | Richiesto |
| Conversazioni/thread | ID thread Gmail | Presente | Implicito nell'esperienza Gmail |
| Eventi calendario | Google Calendar API | Assente | Richiesto |
| Inviti `.ics` e risposte RSVP | Parsing iCalendar e gestione delle risposte | Presente: parser, RSVP accetta/rifiuta/forse, `METHOD:REPLY`, istanze ricorrenti (`Support/CalendarInvite.swift`, `Support/ICSTimeZone.swift`) | Richiesto |
| PGP | Firma, verifica, cifratura, decifratura | Assente | Richiesto |
| Undo send | Invio differito locale con finestra di annullamento | Presente (`App/MailStore+Compose.swift`); comportamento ad arresto/riavvio dell'app durante la finestra da verificare | Richiesto |
| Snooze | Funzione personalizzata: Gmail API non espone uno snooze nativo generale | Presente ma solo locale (colonna `snoozeUntil`): non allineato allo snooze di Gmail Web e mobile | Richiesto; progettazione aperta |
| Unsubscribe | Intestazioni `List-Unsubscribe` e `List-Unsubscribe-Post` | Presente, incluso one-click RFC 8058 (`Support/ListUnsubscribe.swift`) | Richiesto |
| Filtri automatici | Filtri Gmail server-side quando disponibili | Parziale: sola lettura (`GET /settings/filters`); creazione e modifica mancanti | Richiesto |
| Funzionamento offline | Cache SQLite e sincronizzazione incrementale | Presente: cache cifrata, FTS5, coda delle operazioni offline | Proposto |
| Più account | — | Presente: inbox unificata multi-account | Da decidere se mantenerlo (sezione 7) |

## 5. Autenticazione e sviluppo locale

- Il client mostra il consueto flusso «Accedi con Google» nel browser di sistema; il redirect torna a un listener locale su `127.0.0.1`.
- L'app richiede accesso offline e conserva il refresh token nel Keychain; i token di accesso vengono rinnovati automaticamente.
- È preferibile riutilizzare lo stesso OAuth Client ID durante lo sviluppo, evitando revoche o rigenerazioni inutili dei token.
- Per gli scope Gmail, un progetto OAuth esterno in Testing produce refresh token con scadenza a 7 giorni. È stata proposta la modalità In production per l'uso personale, da verificare rispetto alle policy Google applicabili e agli avvisi di app non verificata.
- Gli scope richiesti oggi sono `gmail.modify`, `gmail.settings.basic`, `userinfo.email` e `userinfo.profile`. L'integrazione Calendar aggiungerà uno scope e richiederà un nuovo consenso per ogni account già collegato.
- La configurazione OAuth di Google è distinta dalla pubblicazione sul Mac App Store.
- I token possono comunque essere invalidati per revoca, inattività, modifiche alle credenziali o controlli di sicurezza: non è garantito un accesso perpetuo.

## 6. Vincoli tecnici e rischi

1. Snooze: assenza di una API pubblica generale per lo snooze nativo Gmail. Lo snooze del fork è locale, quindi un thread posticipato nell'app non risulta posticipato in Gmail Web o mobile e viceversa: è una divergenza dall'obiettivo di fedeltà della sezione 1. Definire semantica, notifiche e comportamento con app chiusa.
2. Undo send: l'e-mail non viene richiamata dopo l'invio; bisogna ritardare l'invio effettivo e gestire arresti/riavvii dell'app.
3. Sincronizzazione: utilizzare history.list e prevedere la ricostruzione quando l'ID di cronologia non è più valido (il fork gestisce già il caso `historyExpired`). Per un client solo desktop, valutare polling; le notifiche push Gmail richiedono Google Cloud Pub/Sub.
4. OAuth Gmail: `gmail.modify` è uno scope restricted, con limitazioni e requisiti di verifica (assessment CASA) in caso di distribuzione più ampia. Il modello "ognuno porta il proprio client OAuth" del fork evita la verifica finché l'app non viene distribuita con un client condiviso.
5. PGP: gestione delle chiavi, interoperabilità MIME e sicurezza del rendering richiedono progettazione specifica. Vanno inoltre definiti i flussi esistenti che toccano il testo in chiaro: bozze sincronizzate su Gmail, indice FTS locale e funzioni AI.
6. Calendario: distinguere inserimento evento, modifica/cancellazione e risposta RSVP all'organizzatore. Con la Calendar API evitare la doppia risposta (e-mail `METHOD:REPLY` più aggiornamento via API).
7. HTML e-mail: isolare contenuti attivi e controllare caricamento di risorse remote.
8. Identità del fork: bundle ID (`dev.ronboger.MishMail`) e canale di aggiornamento (`ronboger/mishmail`) sono ancora quelli dell'upstream. Finché non cambiano, il fork collide con un'eventuale installazione upstream e l'updater proporrebbe le release upstream, sostituendo il fork.
9. Divergenza dall'upstream: l'upstream è attivo (v0.7.0 del 13 novembre 2026) e le remediation toccano file grandi (`MailStore.swift`, `SettingsView.swift`, `UpdateChecker.swift`); ogni PR locale aumenta il costo dei futuri allineamenti.

## 7. Questioni aperte

- Verificare compilazione ed esecuzione dei test di MishMail su macOS; verificare compilazione, architettura, test, licenza e dipendenze di Postie. La licenza MIT di MishMail è confermata nel file `LICENSE`.
- Definire il set minimo di funzionalità della prima versione (MVP).
- Stabilire se mantenere il supporto multi-account già presente nel fork.
- ~~Stabilire se mantenere le funzioni AI e il server MCP del fork.~~ Deciso: spenti per il momento (DEC-011). Sono estranee all'obiettivo della sezione 1 e concentrano quattro finding su dodici (F-05, F-06, F-12 e parte di F-04); disattivarle ridurrebbe la remediation.
- **Definire il rapporto con l'upstream:** proporre a monte le correzioni di sicurezza o mantenerle solo nel fork; segnalare in modo riservato F-01, che riguarda anche gli utenti upstream, secondo `SECURITY.md`.
- Definire lo snooze: con app chiusa, su dispositivi diversi e rispetto allo snooze di Gmail Web e mobile.
- Selezionare la libreria OpenPGP e il modello di gestione chiavi; decidere il trattamento di bozze, ricerca e AI per i messaggi cifrati.
- Definire integrazione Google Calendar (scope, nuovo consenso, doppia risposta RSVP) e notifiche.
- Validare la configurazione Google Cloud OAuth per uso personale duraturo.
- Stabilire se in futuro distribuire l'app ad altri utenti.

## 8. Strategia di sviluppo: MishMail + Postie

Repository di sviluppo (fork): bateman/mishmail
Repository upstream (originale): ronboger/mishmail
Repository di riferimento Postie: igorkulman/Postie

Il repository bateman/mishmail è il riferimento per il lavoro sul progetto; mantenere l'upstream distinto per seguire le modifiche originali ed eventualmente integrarle. Al 23 novembre 2026 il `main` del fork coincide con il commit auditato `18294fa`.

Decisione di indirizzo (DEC-007). Partire da un fork di MishMail come applicazione principale, mantenendone — previa verifica — l'interfaccia SwiftUI, il modello locale e l'integrazione Gmail API. Studiare Postie come sorgente selettiva di componenti: non fondere automaticamente i due repository. MishMail è Swift/SwiftUI con licenza MIT (verificato); per Postie la stessa dichiarazione resta da confermare nei file LICENSE e nelle dipendenze prima di copiare codice.

### 8.1 Responsabilità dei progetti

| Progetto | Ruolo previsto | Nota |
|---|---|---|
| **MishMail — [fork bateman/mishmail](https://github.com/bateman/mishmail)** | Base del fork: app, UI, account, modello dati, sincronizzazione, funzionalità di produttività | Conservare ciò che supera l'audit; non assumere robustezza dal solo README. |
| **Postie** | Repository di riferimento: confronto di test e casi limite ICS/RSVP, possibili componenti di composer/sync | Riutilizzare solo ciò che supera confronto, test e analisi delle dipendenze. Non è più la fonte primaria di ICS/RSVP. |
| **Codice nuovo nel fork** | Funzionalità mancanti, integrazioni e adattatori | Preferire moduli isolati, testabili e privi di duplicazioni. |

### 8.2 Componenti da valutare per il trasferimento

| Priorità | Componente | Approccio |
|---|---|---|
| **P0** | **OAuth, token e Gmail API** | Confrontare sicurezza, retry, paginazione e gestione errori dei due progetti; **non** sostituire il client OAuth funzionante senza evidenze di beneficio. |
| **P1** | **Inviti ICS e RSVP** | Già implementati in MishMail. Fare una gap analysis rispetto a Postie (casi limite del parser, fusi orari, aggiornamenti e cancellazioni, test) e portare solo ciò che manca. Declassato da P0 nella v0.7. |
| **P1** | **Composer, bozze e allegati** | Valutare componenti specifici e importare soltanto quelli migliori rispetto alla base. |
| **P1** | **Sync incrementale e recupero** | Confrontare `historyId`, ricostruzione dopo invalidazione, quota/rate limit, offline e operazioni pendenti. Preferire miglioramenti chirurgici. |
| **P1** | **Test, fixture e demo** | Adattare test automatici indipendenti da account reali; mantenere tracciabilità del codice di provenienza. |

Funzionalità assenti nel fork, da implementare: calendario Google completo, OpenPGP, creazione e modifica dei filtri Gmail server-side.

Funzionalità presenti nel fork, da verificare in uso e completare dove serve: colori e gestione delle label, unsubscribe RFC 8058, sicurezza HTML, shortcut configurabili, snooze, undo send. La v0.6 le elencava come non coperte.

### 8.3 Regole per integrare codice tra i due progetti

1. Audit prima del fork operativo: clonare, compilare ed eseguire test e modalità demo di entrambi; controllare stato manutenzione, licenze di progetto e dipendenze, vulnerabilità e struttura del codice.
2. Mappare le dipendenze: per ogni funzionalità candidata individuare file/classi, modelli, networking, OAuth, persistenza e test collegati.
3. Separare logica e interfaccia: estrarre la parte riutilizzabile in un servizio/modulo Swift autonomo; evitare di introdurre due database, due client Gmail o due gestori OAuth.
4. Adattare, non incollare: interfacciare il modulo con modelli e servizi già esistenti in MishMail, documentando modifiche e provenienza.
5. Test prima del merge: test unitari, integrazione Gmail con fixture/mocks, verifica regressioni di sync e UI; poi test limitati su account reale dedicato.
6. Conformità licenze: conservare copyright e avvisi MIT applicabili, verificare anche le licenze di ogni componente e dipendenza trasferiti. Registrare file e commit sorgente nel PR.
7. Mantenibilità: preferire cherry-pick/adattamento tracciato o moduli isolati al copia-incolla indiscriminato; confrontare periodicamente i cambi upstream senza prevedere merge automatici. La regola vale anche per l'upstream MishMail, non solo per Postie.

### 8.4 Roadmap operativa

☐ Milestone 0 — Validazione della base e sicurezza: audit statico completato sul commit `18294fa`. Ordine: (a) build pulita in Xcode, test nativi e demo; (b) decisione GO / NO-GO su MishMail come base; (c) solo in caso di GO, remediation P0/P1. La v0.6 metteva la decisione dopo le remediation.
☐ Milestone 1 — Fork stabile: identità propria (bundle ID, nome app, canale di aggiornamento, plist launchd in `scripts/`), attribuzioni/licenze, build riproducibile, updater disabilitato (DEC-009), OAuth Client ID personale e persistenza sessione, smoke test Gmail/SQLite/shortcuts.
☐ Milestone 2 — ICS/RSVP: verifica su inviti reali dell'implementazione esistente; gap analysis rispetto a Postie e porting selettivo solo di ciò che manca.
☐ Milestone 3 — Parità Gmail: completamento di label e colori, creazione e modifica dei filtri lato server, verifica di shortcuts, undo send e unsubscribe già presenti, riprogettazione dello snooze; validazione con Gmail Web.
☐ Milestone 4 — Calendario e PGP: Google Calendar API (nuovo scope), modifiche/cancellazioni eventi, firma/verifica e cifratura/decifratura OpenPGP; revisione sicurezza.
☐ Milestone 5 — Qualità desktop: accessibilità macOS, performance con caselle grandi, offline, packaging e aggiornamenti.

Criteri per cambiare base e passare a Postie: MishMail non compila in modo riproducibile, presenta problemi di sicurezza/architettura costosi da correggere, o la migrazione richiesta supera il costo di implementare in Postie le funzionalità mancanti. In tal caso documentare un nuovo ADR: la scelta attuale non è irreversibile.

## 9. Progetti di riferimento — shortlist prioritaria

Obiettivo della ricognizione: studiare soluzioni esistenti prima di progettare o implementare da zero autenticazione, sincronizzazione, modello locale e interazioni. La shortlist include cinque progetti open source e un benchmark proprietario. MishMail è ora il candidato principale per il fork; Postie il primo riferimento di confronto (sezione 8). Gli altri restano riferimenti di confronto.

| Priorità | Progetto | Tipo / tecnologie dichiarate | Cosa analizzare | Link |
|---|---|---|---|---|
| P0 | **Postie — riferimento selettivo** | Open source; SwiftUI, Gmail API, SQLite | Architettura macOS nativa; OAuth; sincronizzazione; cache; test e demo | [GitHub](https://github.com/igorkulman/Postie) |
| P0 | **MacMail** | Open source; SwiftUI/AppKit, Gmail API, Google Calendar, SQLite | Integrazione Gmail + Calendar; composer; undo send; allegati; multiaccount | [GitHub](https://github.com/d-sanoj/MacMail) |
| P0 | **MishMail — base del fork** | Open source; SwiftUI, Gmail API, SQLite | Local-first; modello dati; navigazione da tastiera; demo senza account | [Fork](https://github.com/bateman/mishmail) · [Upstream](https://github.com/ronboger/mishmail) |
| P1 | **Exo** | Open source; Rust/egui, Gmail e Calendar API | Workflow stile Superhuman; split inbox; snooze; send later; shortcuts | [GitHub](https://github.com/m1guelpf/Exo) |
| P1 | **Thunderbird** | Open source; desktop multipiattaforma | OpenPGP; MIME; HTML; inviti ICS/RSVP; robustezza e test | [GitHub](https://github.com/thunderbird/thunderbird-desktop) |
| UX | **Mimestream** | **Proprietario**; client macOS per Gmail | Benchmark per label/colori, thread, ricerca, filtri, UX macOS e integrazione Gmail | [Sito](https://mimestream.com/) |

Ordine operativo: verificare prima MishMail e Postie e applicare la roadmap della sezione 8; consultare MacMail per Calendar/composer, Exo per interazioni, Thunderbird per PGP/MIME e Mimestream per benchmark UX.

Checklist di analisi (da compilare per ciascun progetto):

☐ Verificare che repository, licenza e attività di manutenzione siano effettivamente disponibili e aggiornati.
☐ Mappare architettura, dipendenze e versione degli strumenti di build.
☐ Esaminare OAuth/PKCE, Keychain e rinnovo dei token.
☐ Esaminare Gmail API: paginazione, historyId, recovery, rate limiting, sincronizzazione offline.
☐ Esaminare schema SQLite, FTS, thread, label e gestione delle operazioni pendenti.
☐ Esaminare UI nativa, shortcut, accessibilità, performance e test.
☐ Valutare sicurezza: rendering HTML, contenuti remoti, allegati, PGP e dati locali.
☐ Registrare cosa riutilizzare, cosa riprogettare e i rischi di licenza.

## 10. Altri progetti — backlog per analisi futura

Questa lista conserva tutti gli altri nomi emersi nella ricognizione, separati dalla shortlist. I dettagli funzionali sono piste di analisi, non funzionalità verificate eseguendo le app. Verificare sempre repository, licenza, disponibilità del codice e stato di manutenzione prima di pianificare riuso.

### 10.1 Gmail-centrici e client desktop sperimentali

| Progetto | Link | Motivo di interesse |
|---|---|---|
| **7orb** | [Sito](https://7orb.com/) | Swift 6/SwiftUI, OAuth, GRDB, `historyId`, label e cache offline; distinguere roadmap da codice effettivo e verificare il repository. |
| **MailRovers** | [GitHub](https://github.com/wilbertliu/mailrovers) | Local-first, sincronizzazione Gmail, recupero delle operazioni, FTS5. |
| **Mach** | [GitHub](https://github.com/bborn/mach) | Rust/Tauri/React; Gmail + Calendar; comandi e scorciatoie. |
| **Velo** | [GitHub](https://github.com/hscale/velo-email-client) | Label, drag & drop, snooze, unsubscribe, filtri, command palette. |
| **Meru** | [GitHub](https://github.com/zoidsh/meru) · [Sito](https://meru.so/) | Wrapper/integrazione desktop di Gmail; notifiche, multiaccount e personalizzazioni; meno pertinente come base SwiftUI. |
| **Morrow Mail** | [GitHub](https://github.com/Coke1120/Morrow-Mail) | Gmail API, calendario, multiaccount, workflow avanzati. |
| **EmailOps** | [GitHub](https://github.com/emailops/emailops) | Undo send, scheduled send, snooze, unsubscribe, notifiche, calendario. |
| **Godwit** | [GitHub](https://github.com/godwit-email/godwit) | Estensibilità e architettura a plugin. |

### 10.2 Client macOS nativi e progetti Apple

| Progetto | Link | Motivo di interesse |
|---|---|---|
| **MMail** | [GitHub](https://github.com/moerdowo/MMail) | SwiftUI/IMAP; shortcut; rendering HTML e protezioni privacy. |
| **Letterbox** | [GitHub](https://github.com/Mr-vero/letterbox) | SwiftUI; classificazioni Needs Reply, To Do, Waiting. |
| **Minimail** | [GitHub](https://github.com/paperfoot/minimail-mac) | SwiftUI; menu bar, notifiche interattive, snooze, undo send. |
| **Brev** | [Sito](https://brevmail.eu/) | Client nativo Apple; Gmail API/IMAP dichiarati, sorgente e licenza da verificare. |
| **Mailflare** | [Sito macOS](https://mailflare.co/macos) | SwiftUI + core Rust dichiarati; coda offline e separazione dei componenti. |

### 10.3 Sicurezza, protocolli e progetti multipiattaforma

| Progetto | Link | Motivo di interesse |
|---|---|---|
| **Penguin Mail** | [GitHub](https://github.com/c9dev/penguin-mail) | GTK/Rust; OpenPGP, S/MIME, contatti, calendario e regole. |
| **Pelton** | [Sito](https://pelton.app/) | OpenPGP/S/MIME, command palette, ricerca offline; verificare sorgente e licenza. |
| **Mailspring** | [GitHub](https://github.com/Foundry376/Mailspring) | Separazione tra UI e motore di sync; plugin, snooze, send later, regole. |
| **Geary** | [GitLab](https://gitlab.gnome.org/GNOME/geary) | Threading, visualizzazione conversazioni e UX essenziale. |
| **KMail / Kontact** | [GitHub](https://github.com/KDE/kmail) | Integrazione posta, calendario, MIME e crittografia. |
| **Evolution** | [GitLab](https://gitlab.gnome.org/GNOME/evolution) | iCalendar, RSVP, contatti, gestione avanzata delle caselle. |

### 10.4 Benchmark proprietari (UX e funzionalità; non codice da riutilizzare)

| Prodotto | Link | Motivo di interesse |
|---|---|---|
| **Briskmail** | [Sito](https://briskmail.app/) | AppleScript, Siri/Shortcuts, CLI, scorciatoie Gmail, outbox e integrazione macOS. |
| **bytemail** | [Funzionalità](https://bytemailapp.com/features) | Undo send, snooze, unsubscribe, antitracking, Smart Tabs e workflow da tastiera. |

Mimestream è già nella shortlist (sezione 9) ed è quindi intenzionalmente non duplicato in questa tabella.

## 11. Analisi UI/UX — riferimenti per la fase futura

Stato: benchmark e indirizzo progettuale, non decisione di redesign. Il fork di MishMail rimane la base applicativa candidata (DEC-007). Non si assume che la sua interfaccia sia quella definitiva: prima di modificarla, confrontare applicazioni in uso reale su macOS, non solo screenshot e liste di funzionalità. Le valutazioni sottostanti sono qualitative e preliminari, non risultati di test comparativi sistematici.

### 11.1 Classifica di riferimento (UX macOS per Gmail)

| Posizione indicativa | Applicazione | Punti di forza UX da studiare | Limiti dell'analisi |
|---|---|---|---|
| **1 — Mimestream** | [Sito](https://mimestream.com/) | Migliore riferimento **complessivo** per tradurre Gmail in convenzioni macOS: layout a tre pannelli, densità informativa, label e colori, conversazioni, toolbar, menu contestuali, navigazione mouse/tastiera. | Proprietario; valutazione basata su materiale pubblico e recensioni, da validare con prova diretta. |
| **2 — Briskmail** | [Sito](https://briskmail.app/) | Workflow desktop, shortcut Gmail, AppleScript/Shortcuts, automazioni e integrazione macOS. | Meno riscontri indipendenti sulla qualità d'uso quotidiana. |
| **3 — bytemail** | [Funzionalità](https://bytemailapp.com/features) | UI compatta e moderna, azioni rapide, snooze, undo send, unsubscribe e produttività. | Verificare ergonomia, comportamento effettivo e supporto delle funzioni dichiarate. |
| **4 — MishMail** | [GitHub](https://github.com/ronboger/mishmail) | Riferimento open source: command palette, navigazione keyboard-first, viste salvate e flussi di produttività. | Potenzialmente meno rifinito dei prodotti commerciali; richiede test e audit dell'interfaccia. |

Sintesi: Mimestream come benchmark UI/UX primario, Briskmail per shortcut e integrazioni macOS, bytemail per workflow e interazioni compatte, MishMail per base implementativa e funzionalità avanzate. Postie resta un riferimento tecnico di confronto, non il benchmark estetico principale.

### 11.2 Principi UX proposti per il nostro client

- Nativo prima di tutto: selezioni multiple, drag & drop, menu, toolbar, focus, scorciatoie, menu contestuali e accessibilità coerenti con macOS; ricorrere ad AppKit quando SwiftUI non offre comportamento desktop adeguato.
- Gmail senza sembrare una web app: rappresentare esplicitamente thread, label multiple, colori e ricerca Gmail, ma con finestre e controlli macOS.
- Densità configurabile: molte conversazioni visibili senza sacrificare leggibilità; prevedere anteprima, dimensioni pannelli e preferenze di visualizzazione.
- Mouse e tastiera di pari livello: shortcut Gmail, command palette e azioni rapide, senza nascondere operazioni fondamentali agli utenti mouse.
- Feedback immediato: indicatori chiari per sincronizzazione, attività offline, invio in coda/undo send, snooze, esito di operazioni sulle label e problemi OAuth.
- Sicurezza e fiducia: segnalare allegati, mittenti, messaggi cifrati/firmati, contenuti remoti bloccati e stato PGP in modo comprensibile.
- Personalizzazione ragionata: evitare di replicare automaticamente ogni dettaglio del layout MishMail o Gmail Web; preferire convenzioni e controlli utili nell'uso quotidiano del Mac.

### 11.3 Piano di confronto UX prima del redesign

☐ Installare e provare Mimestream, Briskmail e bytemail (quando disponibili in prova) e compilare/eseguire MishMail.
☐ Confrontare lo stesso set di attività: triage inbox, selezione multipla, archiviazione, label e colori, ricerca, composer, allegati, navigazione tra thread, snooze e undo send.
☐ Misurare numero di click/tasti, scoperta delle azioni, feedback, prestazioni percepite, densità e prevedibilità del focus.
☐ Verificare VoiceOver, navigazione completa da tastiera, contrasto, modalità scura, dimensionamento finestre e gestione di mailbox grandi.
☐ Catalogare pattern da mantenere, da adattare e da evitare, con screenshot e brevi note (non copiare asset proprietari).
☐ Prototipare soltanto i punti critici in SwiftUI/AppKit, poi valutare il costo di integrazione nel fork.
☐ Formalizzare un'eventuale decisione successiva (nuovo ADR) prima di intraprendere una riscrittura significativa della UI.

Collocazione nella roadmap: eseguire il confronto ergonomico durante Milestone 1–3; concentrare eventuale rifinitura sostanziale nella Milestone 5 — Qualità desktop, senza bloccare l'avanzamento delle funzionalità Gmail/ICS/PGP.

## 12. Security audit del fork (baseline)

Fonte: rapporto Codex SECURITY_AUDIT.md, fornito integralmente nella conversazione. **Il file non è nel repository:** va aggiunto (o collegato) perché questo documento lo indica come fonte di dettaglio.
Repository: bateman/mishmail
Commit esaminato: 18294fa653524cf02a77ddfd0e34db64b8fc09b2 (main)
Data audit: 22 novembre 2026 (UTC)
Metodo: sola lettura del codice, ricerche statiche mirate, controlli sintattici e prove sintetiche isolate su Linux. Nessun test nativo macOS né uso di credenziali o account reali.
Tracciabilità: tutti i riferimenti a file e righe sotto si riferiscono solo al commit esaminato; dopo modifiche dovranno essere rivalutati.
Revisioni precedenti: il repository contiene già `docs/security-review.md` e `docs/security-review-2026-07-29.md`, non considerate dall'audit. Vanno confrontate con i finding per individuare sovrapposizioni e rilievi già chiusi.
Controllo a campione (v0.7): i riferimenti di riga di F-01, F-02, F-07 e il percorso allegati di F-04 corrispondono al codice del commit auditato.

### 12.1 Esito e interpretazione

12 finding: 1 High, 8 Medium, 3 Low; 0 Critical dimostrati. Severità condizionate dai prerequisiti descritti. Le debolezze sono state identificate nei flussi sorgente, non sono exploit riprodotti su macOS, né prova di compromissione del canale di rilascio.

Il rischio principale riguarda la fiducia iniziale dell'updater per build firmate ad hoc: accetta qualunque publisher Developer ID notarizzato se l'app installata non possiede un Team ID. È necessario il compromesso del canale di release o metadata malevoli. Il canale attualmente configurato è ronboger/mishmail, non bateman/mishmail. Le installazioni già firmate con Team ID richiedono corrispondenza del Team ID ancorato ad Apple.

Una build locale Xcode firmata ad hoc è esattamente lo scenario di F-01, e l'updater avvia da solo controlli orari all'avvio dell'app (`App/MishMailApp.swift:153`). Il rischio è quindi attuale già in sviluppo, non solo in distribuzione.

Le lacune privacy confermate riguardano: fallback scrivibile su database legacy in chiaro, logging pubblico con identificativi e corpi degli errori, persistenza di allegati e copie AI dopo la rimozione dell'account, trasporto HTTP remoto non vincolato per lo script di riepilogo AI. Inoltre, consenso host legacy e discovery dei modelli possono trasferire credenziali verso origini nuove senza approvazione adeguata.

### 12.2 Registro completo dei rilievi

| ID | Severità | Rilievo | Evidenza principale | Condizione/rischio |
|---|---|---|---|---|
| **F-01** | **High** | Updater non vincola il publisher nelle installazioni ad hoc | `Sources/MishMail/Support/UpdateChecker.swift:704–733` | Canale release compromesso + binario attacker-signed notarizzato; nessuna compromissione accertata. |
| **F-02** | Medium | Database legacy plaintext resta scrivibile durante conversione differita | `Sources/MishMail/Store/Database.swift:1077–1083` | Cache legacy + conversione busy/istanza concorrente; dati nuovi in chiaro. |
| **F-03** | Medium | Log espongono indirizzi account ed errori API non oscurati | `Sources/MishMail/Support/DiagnosticLog.swift:46–84` | Evento di errore, log condiviso/raccolto; nessuna perdita token dimostrata. |
| **F-04** | Medium | Rimozione account non elimina tutti gli allegati e chat AI | `Sources/MishMail/App/MailStore+Accounts.swift:65–106` | Allegato già aperto o conversazione AI contenente dati mail. |
| **F-05** | Medium | Summarizer CLI accetta destinazioni HTTP remote con contenuti mail/chiavi | `scripts/mcp-summarize.py:77–88` | Endpoint HTTP remoto configurato dall'utente; verificato con transport mock. |
| **F-06** | Medium | Consenso legacy per host AI trasferito a un host differente | `Sources/MishMail/UI/SettingsView.swift:2323–2329` | Record legacy host-only + modifica host dell'utente. |
| **F-12** | Medium | Fetch models invia credenziali salvate a endpoint modificato non approvato | `SettingsView.swift:2340–2341,2423–2428`; `Support/LLMClient.swift:460–471` | Utente cambia endpoint, usa discovery; key/token provider riutilizzato. |
| **F-07** | Medium | Updater da terminale permette rollback a release vecchia firmata | `scripts/update-mishmail.sh:66–71` | Metadata release malevoli/obsoleti + uso script di aggiornamento. |
| **F-08** | Medium | Download/estrazione update privi di limiti di risorse applicativi | `Support/UpdateChecker.swift:403–405,567–575` | Archivio malevolo consegnato; traversal non dimostrato. |
| **F-09** | Low | Listener OAuth senza timeout e limite per connessione | `Auth/OAuth.swift:276–278,384–400` | Flood da processo locale durante login. |
| **F-10** | Low | Provenienza build, action CI e permessi non sufficientemente fissati | `.github/workflows/ci.yml:15–76`; `project.yml:8–10` | Compromissione di input CI/toolchain; nessuna CVE della dipendenza accertata. |
| **F-11** | Low | Anteprime notifiche replicano dati mail fuori dalla cache cifrata | `App/MailStore+Sync.swift:415–418`; `Support/Notifier.swift:11–16` | Notifiche abilitate e configurazione anteprime del sistema. |

### 12.3 Dettagli e remediation per finding

F-01 — Trust dell'updater (High). Se manca il runningTeam, la validazione verifica Developer ID e notarizzazione ma non uno specifico publisher; officialRelease non costituisce un vincolo effettivo. Il checksum, quando presente, proviene dallo stesso canale release. Lo script e l'app puntano all'upstream ronboger/mishmail. Correzione: per build locali ad hoc, disabilitare la sostituzione automatica dell'app. Per la distribuzione, configurare esplicitamente canale del fork, identità applicativa, requisito di firma Apple oppure chiave di aggiornamento indipendente; mantenere controlli notarizzazione, firme annidate, checksum e anti-rollback. L'accesso a Keychain da un eventuale sostituto resta una decisione separata del sistema operativo.

F-02 — Plaintext legacy (Medium). In caso di conversione occupata/disabilitata, Database.swift:1077–1083 sceglie .plaintext, omette usePassphrase e apre un DatabasePool scrivibile (:768–796). Correzione: bloccare la scrittura e la sincronizzazione di posta reale finché la conversione cifrata non completa; prevedere, se necessario, sola lettura di recupero. Testare migrazione con istanze concorrenti, quick_check, header e impossibilità di leggere schema/WAL senza chiave.

F-03 — Diagnostica (Medium). DiagnosticLog.swift:46–62 pubblica account, endpoint e fino a 4.000 caratteri del body HTTP via log privacy: .public e file testuale; non è provato che contenga token. Correzione: usare codici stato/categorie, endpoint parametrizzati, mascheramento/hashing degli account; niente body grezzi per default; permessi 0700/0600, retention esplicita e modalità diagnostica opt-in temporanea.

F-04 — Retention dopo rimozione (Medium). MailStore.swift:4447–4490 crea allegati in temporaryDirectory/MishMailAttachments/...; la rimozione account elimina token e righe principali ma non quell'albero né le conversazioni AI che possono includere risultati di get_thread (AskMishController.swift:1183–1204). Correzione: cleanup protetto da symlink e scadenza cache, metadati di provenienza account/thread per chat AI, scelta esplicita su cancellazione/retention, rimozione notifiche; considerare copie in backup e cache OS.

F-05 — HTTP helper AI (Medium). mcp-summarize.py:77–88,125–136 può inviare e-mail e bearer API key a --api-base HTTP remoto, aggirando le regole native; prova sintetica con dummy e mock, senza rete reale. Correzione: HTTP solo su loopback letterale, HTTPS da remoto, validazione redirect e flag di consenso per contenuti mail remoti; chiavi fuori da argomenti CLI, file sensibili 0600.

F-06 — Consenso legacy (Medium). In SettingsView.swift:2323–2329, il consenso salvato per il vecchio host può restare vero dopo cambio dell'URL; il salvataggio persiste quindi il consenso per il nuovo endpoint. Correzione: consentire migrazione solo a origin originale validata, azzerare consenso dopo variazione origin/scheme/porta e ricontrollare al salvataggio; regression test del caso legacy.

F-12 — Discovery credenziali (Medium). Fetch models può essere attivo con consenso disabilitato; costruisce una richiesta con ID provider già salvato a un URL modificato. LLMClient.listModels applica autenticazione senza controllo del consenso host, permettendo invio della chiave salvata. Correzione: associare i segreti all'origin autorizzata e applicare il controllo condiviso prima di ogni richiesta autenticata (discovery, test e generazione); non trasmettere credenziali a host nuovo fino a nuova autorizzazione; test che confermi zero chiamate al transport.

F-07 — Anti-rollback CLI (Medium). update-mishmail.sh:66–71 blocca solo versioni uguali; può sostituire una versione nuova con una vecchia ancora firmata. Correzione: confronto numerico autenticato NEW_VERSION > CURRENT, coerente con updater nativo; downgrade soltanto con opzione di recovery esplicita; controllo di bundle ID e signing requirement.

F-08 — Bounded extraction (Medium). UpdateChecker.swift:403–405,567–575 scarica ed estrae ZIP con ditto senza limiti applicativi di byte, numero entry, dimensione espansa, tempo o spazio disponibile. Correzione: limiti imposti durante il download e la decompressione, estrazione in directory privata, controllo path e symlink, deadline e riserva disco. Non è stato dimostrato un path traversal o un exploit di ditto.

F-09 — OAuth listener (Low). Il listener su 127.0.0.1 ha stato e PKCE robusti, ma le singole connessioni non hanno deadline/concurrency cap. Correzione: limite connessioni, deadline di lettura, tracking e cancel alla fine del login; test sintetici di client locali lenti.

F-10 — Supply chain (Low). actions/*@v4 è mutabile, xcodegen Homebrew non è fissato, workflow CI non specifica permissions:. Dipendenza GRDB/SQLCipher selezionata come binario: manifest 3.0.0 con checksum 41f01022f6a35986393e063e1ef386fd896646ed032f7d0419c4b02fa3afe61d, tag risolto 46098847eeabdb008f238bef5750a8e64097b6ed; binary non verificato e nessuna CVE asserita. Correzione: permessi contents: read, commit SHA per le action, toolchain pinned, dependency lock/provenance e SBOM binario.

F-11 — Notifiche (Low). UNMutableNotificationContent conserva mittente, oggetto o snippet fuori dal database SQLCipher; l'esposizione dipende dalle preferenze macOS. Correzione: anteprima generica "Nuova e-mail" come default privacy, opt-in separati, ID notifiche legati all'account e pulizia alla sua rimozione.

### 12.4 Controlli di sicurezza osservati nel codice

Il rapporto non ha dimostrato l'assenza delle protezioni principali; ha invece confermato in sorgente:

1. OAuth: PKCE S256, verifier casuale 64 byte, state 32 byte, confronto dello state su callback riusciti e d'errore, browser di sistema, loopback 127.0.0.1 e limite request-line 16 KiB (Auth/OAuth.swift).
2. Token: refresh coalescente con controllo di generazione, margine scadenza; Keychain non sincronizzato AfterFirstUnlockThisDeviceOnly; accessibilità e ACL da verificare su macOS (GmailClient.swift, AccessTokenCache.swift, Keychain.swift).
3. Storage: chiave casuale 256 bit in Keychain, usePassphrase, tabelle temporanee in RAM, procedure di export/quick_check per migrazione; resta l'eccezione F-02 e manca verifica del codec binario (Database.swift).
4. HTML/WebKit: content JavaScript disabilitato, CSP trusted-first che blocca script, form, frame e oggetti, storage effimero, blocco immagini remote di default, controllo navigazione e reset WebView; CSS/phishing e caricamento immagini approvato restano rischi inerenti (HTMLBodyCSP.swift, WebViewPool.swift).
5. MIME/allegati: basename, header folding, cache con permessi privati, file regolari e controllo symlink, scritture atomiche, avviso estensioni pericolose e tentativi di quarantena; successo di quarantine non verificato (MessageParsing.swift, MailStore.swift).
6. MCP locale: bind loopback, bearer token non vuoto, limiti di richiesta/connessione/lettura, identificazione token a tempo costante, API opt-in; client autenticati hanno intenzionalmente ampio accesso alla posta (MCPServer.swift).
7. Updater nativo: firma annidata e multiarchitettura, continuità Team ID per app già firmate, notarizzazione, signed bundle/tag match e controllo versione numerico; eccezioni F-01, F-07, F-08.
8. Sandbox e AI: sandbox per app e network entitlements; distribuzione con hardened runtime, helper di rilancio intenzionalmente non sandboxed; controllo consenso per generazione AI e conferma delle azioni di scrittura, ma le lacune F-05/F-06/F-12 permangono.
9. Gmail API: base HTTPS fissa, parametri codificati, retry limitati, rate pacing, refresh 401, gestione Retry-After; attenzione allo scope gmail.settings.basic abilitato anche per lettura filtri.
10. Unsubscribe: sessione effimera e validazione URL/redirect con esclusione indirizzi locali/credenziali; DNS che risolve a indirizzi privati rimane ipotesi da verificare, non SSRF dimostrata.

### 12.5 Evidenza dei controlli eseguiti e limitazioni

| Verifica | Risultato / significato |
|---|---|
| Inventario sorgente | 702 file tracked; 222 Swift sorgente e 219 Swift test (il rapporto indicava 214; corretto nella v0.7). Ricognizione per confini di sicurezza, non revisione di ogni riga. |
| Python | 7 script parsed con `ast.parse`; nessuna esecuzione dei main. |
| Shell | 7 script `bash -n` superati; nessuna prova operativa di update. |
| Plist/entitlements | 5 file sintatticamente letti; distribuzione firmata non verificata. |
| Probe F-05 | `summarize_openai` accetta URL HTTP remoto e prepara richiesta con key e mail sintetiche; trasporto mocked. |
| Probe F-06 | Predicato legacy consente host nuovo nel caso costruito; UI macOS non eseguita. |
| Probe F-07 | La condizione di uguaglianza lascia proseguire downgrade 0.7.0 → 0.6.0; nessun download. |
| Secret scan limitato | Nessun pattern PEM/GitHub token/AWS AKIA/Google API key rilevato nel testo selezionato; non prova completa assenza. |
| Toolchain native | Swift/Xcode/xcodegen/SwiftLint/Semgrep/ShellCheck non disponibili su Linux; XCTest, firma, notarizzazione, WKWebView, Keychain e APFS **non testati**. |
| Dipendenza binaria | Manifest e checksum ispezionati, non scaricato/verificato il framework, né SBOM/CVE delle librerie incluse. |

Ipotesi da verificare in laboratorio macOS: cifratura effettiva SQLite/WAL e comportamento senza chiave; Keychain a schermo bloccato; restrizioni CSP/WebKit e redirect con credenziali; quarantena e symlink su APFS; signed-release identity, release channel e archive bounds; chiusura callback OAuth; backup, crash dump, notifiche e residui AI. L'audit non prova compromissione delle release, furto di token o exploit remoto da una e-mail.

## 13. Piano di remediation e PR — priorità prima delle feature

Regola: per ogni PR includere test di regressione, riferimenti ai finding, comportamento previsto, compatibilità con upgrade/migrazione, e prova su macOS. Le PR sono proposte, non già aperte o implementate. Il documento non cambia il codice del repository.

Le PR partono solo dopo la decisione GO su MishMail come base (Milestone 0). Se le funzioni AI e il server MCP venissero disattivati (questione aperta, sezione 7), PR-03 e la parte AI di PR-05 si ridurrebbero alla verifica della disattivazione.

| Ordine | PR proposta | Finding | Criterio minimo di accettazione |
|---|---|---|---|
| **P0 / PR-01** | Sicurezza release del fork | F-01, F-07 | Update automatico non sostituisce build ad hoc; canale non ereditato senza scelta esplicita; nessun rollback involontario. |
| **P0 / PR-02** | Fail-closed database legacy | F-02 | Nessuna scrittura di mail reali in plaintext; conversione busy produce stato sicuro e test con dati fixture. |
| **P0 / PR-03** | Segreti e consenso AI | F-05, F-06, F-12 | Mai inviare credenziale a origin differente senza autorizzazione; remote HTTP rifiutato nei CLI helper. |
| **P1 / PR-04** | Privacy diagnostica | F-03 | Niente body grezzi/account in log di default; permessi e retention verificati. |
| **P1 / PR-05** | Cancellazione completa account | F-04, F-11 | Allegati/AI/notifiche associati all'account rimossi o esplicitamente conservati per scelta utente. |
| **P1 / PR-06** | Limiti e hardening | F-08, F-09 | Risorse update limitate, connessioni OAuth bounded e cancellate. |
| **P2 / PR-07** | CI/provenance e release gate | F-10 | Permessi minimi, pinning, inventario binari e test native obbligatori, senza skip silenziosi. |

Vincolo di rilascio:

- **Prima dell'uso quotidiano di account Gmail reali:** updater disabilitato sulle build locali (DEC-009, mitigazione di F-01) e F-02, F-03, F-12 risolti o mitigati. La v0.6 rimandava F-01 alla distribuzione, ma l'updater è attivo anche sulle build ad hoc di sviluppo.
- **Prima della distribuzione o di update binari:** F-01 e F-07 risolti in modo completo (canale e identità del fork), insieme ai limiti di F-08.
- **Prima di abilitare i flussi AI in ambienti reali:** F-05 e F-06.

Validare tutto con app compilata e firmata su macOS. La correzione delle vulnerabilità non richiede di importare codice Postie.

## 14. Stato attuale, dipendenze e prossime verifiche

> Aggiornamento v0.8: le PR di remediation sono state eseguite come ondate 1 e 2 del [piano di sviluppo](piano-sviluppo.md), che ne riporta l'esito per finding. L'elenco sotto è quello della v0.7 e resta come traccia.

☑ Audit statico a commit fisso ricevuto, con 12 finding documentati e 0 Critical dimostrati.
☑ Verificato il 23 novembre 2026 che il `main` del fork è ancora a `18294fa`; da ripetere prima di iniziare le PR.
☑ Confronto del documento con il codice del fork (v0.7): corretti stato delle funzionalità, stack e ordine della roadmap.
☐ Eseguire build macOS e test esistenti; confermare che i smoke test di firma/updater non siano saltati.
☐ Decisione GO/NO-GO su MishMail come base.
☐ Decidere su AI/MCP e sul rapporto con l'upstream (sezione 7), perché cambiano l'ampiezza delle PR.
☐ Disabilitare l'updater (DEC-009) e dare al fork identità propria (Milestone 1).
☐ Implementare PR-01/02/03, poi PR-04/05/06/07 in base ai rischi reali e all'uso previsto.
☐ Ripetere regression test di OAuth, SQLCipher, rendering HTML, allegati, AI, update e cancellazione account.
☐ Aggiungere `SECURITY_AUDIT.md` al repository e confrontarlo con le revisioni di sicurezza già presenti in `docs/`.
☐ Solo dopo, riprendere la milestone ICS/RSVP e la gap analysis rispetto a Postie.
☐ Prima di distribuzione: verificare entitlements finali, publisher identity, notarizzazione, provenance e policy OAuth Google.

Fonte canonica: questo documento unifica piano e risultati essenziali dell'audit del 22 novembre 2026. Il report originale SECURITY_AUDIT.md resta la fonte per formulazioni dettagliate, riferimenti di linea addizionali, prove sintetiche e ipotesi non risolte; in caso di divergenza sui rilievi, prevale l'evidenza al commit auditato, da rivalidare sul branch corrente.

## 15. Registro delle modifiche

| Data | Versione | Modifica |
|---|---|---|
| 2026-11-19 | 0.1 | Consolidate decisioni, requisiti, stack proposto e questioni aperte emerse nella conversazione. |
| 2026-11-22 | 0.2 | Aggiunti shortlist prioritaria (Postie, MacMail, MishMail, Exo, Thunderbird, Mimestream), checklist di analisi e backlog separato degli altri progetti open source e benchmark proprietari. |
| 2026-11-22 | 0.3 | Adottato indirizzo **fork MishMail + riuso selettivo Postie**, con criteri di audit, roadmap, condizioni GO/NO-GO, criteri di attribuzione e tracciamento delle integrazioni. |
| 2026-11-22 | 0.4 | Aggiunta analisi UI/UX per la fase futura: benchmark Mimestream, Briskmail, bytemail e MishMail; principi di design e checklist di confronto prima di eventuale redesign. |
| 2026-11-22 | 0.5 | Registrato il repository di sviluppo [bateman/mishmail](https://github.com/bateman/mishmail), distinto dall'upstream [ronboger/mishmail](https://github.com/ronboger/mishmail). |
| 2026-11-23 | 0.6 | Unificato piano di sviluppo e security audit del commit `18294fa`: 12 finding, controlli verificati in sorgente, limiti della verifica, DEC-008/009, priorità remediation e PR proposte. |
| 2026-11-23 | 0.7 | Confronto con il codice del fork. Corretti: stato reale delle funzionalità (ICS/RSVP, unsubscribe, shortcut, colori label, snooze, undo send e multi-account già presenti), stack (Swift 5.10, GRDB/SQLCipher, login loopback al posto di `ASWebAuthenticationSession`), scope `gmail.modify` restricted, conteggio dei test. Aggiunti: updater come prerequisito per gli account reali, identità del fork, GO/NO-GO prima delle remediation, questioni aperte su AI/MCP, upstream, snooze, Calendar e PGP, riferimenti alle revisioni di sicurezza esistenti. Nessuna nuova decisione confermata. |
| 2026-11-24 | 0.8 | Dopo le ondate 1 e 2 del piano di sviluppo: aggiunte DEC-010–016, DEC-009 segnata come implementata, chiusa la questione su AI e MCP. Lo stato di ogni finding e i seguiti sono in [piano-sviluppo.md](piano-sviluppo.md); i riferimenti di riga della sezione 12 valgono solo per il commit auditato `18294fa`. |
| 2026-11-24 | 0.9 | Aggiunte DEC-017–020: shortcut come Gmail Web, pannello di lettura predefinito, "cancellato vuol dire sparito", regola delle chat alla rimozione di un account. L'ondata 3 non è avviata. |
| 2026-11-24 | 0.10 | Dopo la prima prova su Mac: aggiunte DEC-021–024 (icone monocromatiche, correttore in più lingue, colori delle label come in Gmail, stile di comunicazione conciso). La cache persistente e cifrata delle immagini resta un'opzione in attesa delle prove del proprietario, annotata in [piano-sviluppo.md](piano-sviluppo.md). L'ondata 3 non è avviata. |
| 2026-11-24 | 0.11 | Terzo giro di richieste: aggiunte DEC-025–028 (colore della label dell'account, foto profilo Google, warning come errori in CI, icone della barra laterale). L'ondata 3 non è avviata. |
| 2026-11-24 | 0.12 | Quarto giro di richieste: aggiunte DEC-029–040 (forma delle label, anello e titolo dell'account, righe dei messaggi, cache cifrata delle immagini incorporate, immagini remote attive per impostazione predefinita, cache delle immagini remote, colore d'accento configurabile, modifiche semplici senza review, archiviazione e subentro dell'orchestratore, livelli di review, segnalazione di F-01 annullata, avvio dell'ondata 3). Aggiornata DEC-028. DEC-034 è decisa ma ancora in lavorazione (PR #42). L'ondata 3 non è avviata. |
| 2026-11-25 | **0.13** | Aggiunte DEC-041–046: snooze variante B, Google Calendar perimetro B, prima apertura delle immagini remote, avvio dell'ondata 4, PGP perimetro B, calendari per i conflitti scelti dall'utente. |
| 2026-11-25 | **0.14** | Aggiunta DEC-047: libreria OpenPGP rPGP (Rust), previa verifica che non esista una soluzione già pronta. |
| 2026-11-25 | **0.15** | Aggiunte DEC-048 (Calendar: permesso ampio) e DEC-049 (risposta agli inviti sempre su calendario e per e-mail). |
| 2026-11-25 | **0.16** | Aggiunta DEC-050: libreria OpenPGP in un repository separato. |
| 2026-11-25 | **0.17** | Aggiunte DEC-051 (Ed448/X448 e algoritmi deboli rifiutati, avvisi accettati), DEC-052 (e-mail prima del calendario), DEC-053 (badge dei non letti sulla foto profilo). |
| 2026-11-25 | **0.18** | Aggiunte DEC-054 (nel dubbio, come fa Gmail), DEC-055 (firme per account), DEC-056 (impostazioni per account). |
| 2026-11-25 | **0.19** | Aggiunte DEC-057 (barra laterale come Gmail e barra degli account), DEC-058 (`make run` con l'account reale), DEC-059 (rilasci della libreria OpenPGP). |
| 2026-11-25 | **0.20** | Aggiunta DEC-060 (libreria OpenPGP collegata anche a interruttore spento; caricamento dinamico da valutare). |
| 2026-11-25 | **0.21** | Aggiunte DEC-061 (nomi del rebranding a DreaMail) e DEC-062 (Chat e Calendar integrati: solo studio). |
| 2026-11-25 | **0.22** | Aggiunta DEC-063 (barra laterale come Gmail: scostamenti). |

---

> **Regola di manutenzione:** ogni nuova decisione va aggiunta nella sezione 2 con un ID progressivo; le proposte restano distinte dalle decisioni confermate. Aggiornare anche il registro delle modifiche.
