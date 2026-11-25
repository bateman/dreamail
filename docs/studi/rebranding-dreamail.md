# Studio: rebranding da MishMail a DreaMail

Data: 25 novembre 2026
Stato: studio, nessuna modifica al codice. Base: `main` al commit `ba8e7aa`.
Riferimenti: [Registro delle decisioni](../registro-decisioni.md), [Piano di sviluppo](../piano-sviluppo.md), [`docs/naming.md`](../naming.md).

Decisioni del proprietario già prese e trattate qui come dati:

- Il nome è **DreaMail** (D e M maiuscole). Forme derivate: `DreaMail` per tipi, target e bundle ID; `dreamail` per percorsi, URL e schema; `DREAMAIL_` per impostazioni di build e variabili d'ambiente.
- Prefisso C della libreria OpenPGP: `mm_` → `dm_` (simboli `dm_pgp_*`).
- Target della libreria: `MishMailRPGP` → `DreaMailRPGP`.
- "Ask Mish" diventa **"Ask AI"**. Le funzioni AI e MCP restano nel codice, spente (DEC-011).

## 1. Sintesi

**Che cosa comporta.** Il nome compare in 379 file su 902 (2.288 righe) e in 636 percorsi di file. Tolti gli archivi storici, che non vanno toccati, restano 209 file e circa 1.500 righe, più lo spostamento di 636 file (608 solo perché stanno sotto `Sources/MishMail*` o `Tests/MishMail*`). È un lavoro meccanico, eseguibile con uno script, ma tocca quattro cose che vivono fuori dal repository: i bundle ID, il nome del repository GitHub, la libreria `bateman/dreamail-openpgp` e l'installazione sul Mac del proprietario.

**Che cosa si rompe in un'installazione esistente.** L'app è in sandbox e quasi tutto è legato al bundle ID. Cambiando `io.github.bateman.MishMail` in `io.github.bateman.DreaMail`, macOS vede un'app nuova:

- contenitore nuovo e vuoto: database cifrato, allegati, bozze locali, firme, viste salvate e preferenze restano nel vecchio contenitore;
- elementi del Keychain non più letti (il servizio è il bundle ID): token di accesso Google, client secret, chiave del database;
- permesso per le notifiche, client e-mail predefinito e posizione della finestra da reimpostare.

Nulla viene cancellato: i dati vecchi restano sul disco finché non si eliminano a mano. Lato Google non cambia niente: il client OAuth è di tipo "Desktop app", senza legame con bundle ID o nome. Basta accedere di nuovo.

Risulta una sola installazione da considerare, quella del proprietario: il repository non ha release, stelle né fork, e l'updater è spento.

**Raccomandazione.** Un solo cambio completo, bundle ID compresi, senza migrazione automatica dei dati, fatto a `main` fermo:

1. chiudere prima le tre PR aperte (#63, #65, #68);
2. rilasciare la libreria rinominata (`v0.2.0`);
3. una PR unica di rinomina nell'app, generata da uno script;
4. rinomina del repository GitHub subito dopo il merge;
5. sul Mac: installare DreaMail, accedere di nuovo, lasciar risincronizzare, poi rimuovere la vecchia app.

Motivo: una rinomina a metà (nome visibile nuovo, bundle ID vecchio) lascia per sempre il vecchio nome nei percorsi e nel Keychain, oppure rimanda a dopo lo stesso strappo. Il passaggio allo step 1A (`dev.ronboger.MishMail` → `io.github.bateman.MishMail`) è già stato fatto così, senza migrazione. Il vecchio contenitore intatto è anche il modo di tornare indietro.

**Costo.** Circa 2–3 giorni di lavoro di sessione, livello di review standard, più 1–2 ore del proprietario sul Mac e 10 minuti su GitHub.

**Prima di partire.** Il controllo sul nome (sezione 8) ha trovato un quasi omonimo nella stessa categoria: "DreamMail", client e-mail per Windows, a quanto risulta abbandonato. I registri dei marchi UE e internazionali non sono stati verificabili da qui.

## 2. Inventario

Conteggi su `main` a `ba8e7aa`. Comandi per rifarli:

```sh
git grep -ohE 'MishMail' | wc -l          # e così per ogni grafia
git grep -lE  'MishMail' | wc -l
git ls-files | grep -ci mish              # percorsi
git grep -ohE 'MISHMAIL_[A-Z_]+' | sort | uniq -c
git grep -ohE 'io\.github\.[A-Za-z]+\.[A-Za-z.\-]+' | sort | uniq -c
```

### 2.1 Grafie

| Grafia | Occorrenze | File | Nuova forma |
|---|---|---|---|
| `MishMail` | 1.171 | 245 | `DreaMail` |
| `mishmail` | 339 | 167 | `dreamail` |
| `Mishmail` | 0 | 0 | — |
| `MISHMAIL` (sempre `MISHMAIL_…`) | 180 | 55 | `DREAMAIL_…` |
| `Mish` come parola a sé | 233 | 56 | vedi "Ask AI", sezione 2.6 |
| `Ask Mish` | 160 | 49 | `Ask AI` |
| `mm_` (simboli C) | 7 | 1 | `dm_` |
| `DreaMail`/`dreamail` già presenti | 7 | 5 | solo `dreamail-openpgp` |

### 2.2 Per area

"Nome" conta `mishmail` senza distinzione di maiuscole; "Mish" conta `Mish`, `AskMish`, `askMish` e simili.

| Area | Nome: occorrenze / file | Mish | Da rinominare |
|---|---|---|---|
| `Sources/MishMail` (322 file) | 262 / 74 | 290 | sì |
| `Sources/MishMailRelauncher` (4 file) | 22 / 2 | 0 | sì |
| `Tests/MishMailTests` (286 file) | 274 / 63 | 269 | sì |
| `Tests/MishMailUITests` (14 file) | 36 / 14 | 0 | sì |
| `scripts/` | 79 / 14 | 0 | sì |
| `Makefile` | 74 | 0 | sì |
| `project.yml` | 64 | 1 | sì |
| `Config/Signing.xcconfig` | 14 | 0 | sì |
| `.github/` | 10 / 2 | 0 | sì (9 sono dati di prova in `test_ci_checks.py`) |
| `README.md`, `CONTRIBUTING.md`, `SECURITY.md` | 39, 5, 10 | 6 | sì |
| `docs/RELEASING.md`, `docs/DEPENDENCIES.md` | 20, 1 | 0 | sì |
| `.oss-scanner/`, `.gitignore` | 20, 1 | 1 | sì |
| `docs/registro-decisioni.md`, `docs/piano-sviluppo.md`, `docs/naming.md` | 59, 18, 4 | 1 | solo voci nuove; lo storico resta |
| `CHANGELOG.md` | 37 | 23 | no, salvo una voce nuova |
| `docs/codex-reviews` (135 file), `docs/plans`, `docs/superpowers`, `reviews/`, `docs/security-review*.md` | 641 / 165 | 257 | no: archivi |
| `Design/` | 0 | 0 | niente |

### 2.3 Prodotto, target, modulo

Tutto in `project.yml`, da cui xcodegen genera `MishMail.xcodeproj`.

| Voce | Oggi | Tipo di cambio |
|---|---|---|
| Nome del progetto | `name: MishMail` | testuale |
| Target | `MishMail`, `MishMailRelauncher`, `MishMailTests`, `MishMailUITests` | testuale; cambiano anche i tre schemi omonimi |
| Nome del prodotto | `MishMail` (Release), `MishMail Debug` (Debug), `MishMailRelauncher` | cambia il nome del file `.app` e il percorso `/Applications/MishMail.app` |
| Modulo Swift | implicito dal target | nessun `import MishMail` nel repository; l'unico import con il nome è `import MishMailRPGP` |
| Header di collegamento | `Sources/MishMail/Support/MishMail-Bridging-Header.h` (2 riferimenti) | testuale |
| Cartelle dei sorgenti | `Sources/MishMail`, `Sources/MishMailRelauncher`, `Tests/MishMailTests`, `Tests/MishMailUITests` | spostamento di 626 file; i percorsi sono citati in `project.yml`, `Makefile`, test e script |
| File con il nome | `MishMailApp.swift`, `MishMail.entitlements`, `MishMail.Distribution.entitlements`, `MishMailRelauncher.entitlements`, `MishMailSmokeTests.swift`, 7 file `AskMish*.swift`, 5 test `AskMish*Tests.swift`, `scripts/update-mishmail.sh`, `scripts/mishmail-summarize-daily.sh`, `scripts/io.github.bateman.mishmail-summarize.plist` | spostamento |
| Relauncher incorporato | `Contents/Library/MishMailRelauncher.app` (in `project.yml`, `Makefile`, `UpdateInstaller.swift`) | testuale, ma i tre punti devono cambiare insieme |

### 2.4 Identificatori registrati o salvati fuori dal repository

| Voce | Oggi | Dove | Effetto del cambio |
|---|---|---|---|
| Bundle ID app | `io.github.bateman.MishMail` (17 occorrenze) | `project.yml`, `Relaunch.swift`, `Keychain.swift`, test, script, README | **app nuova per macOS** (sezione 3) |
| Bundle ID Debug | `io.github.bateman.MishMail.debug` (9) | `project.yml`, `Makefile`, `PerfMetrics.swift` | come sopra, per la build di sviluppo |
| Bundle ID relauncher | `io.github.bateman.MishMail.Relauncher` (2) | `project.yml`, `ForkIdentityTests` | nessun dato salvato |
| Bundle ID dei test | generati da `bundleIdPrefix: io.github.bateman` + nome del target | `project.yml` | nessun dato salvato |
| Servizio Keychain | il bundle ID a runtime, con ripiego `io.github.bateman.MishMail` | `Support/Keychain.swift:10` | segue il bundle ID |
| Gruppi di accesso Keychain | nessuno (`keychain-access-groups` assente dagli entitlements) | — | niente da rinominare |
| Dominio UserDefaults | quello standard, cioè il bundle ID; nessuna suite condivisa | — | segue il bundle ID |
| Cartella dati | `…/Application Support/MishMail/mail.sqlite`; varianti `MishMailDemo`, `MishMailUITests` | `Store/Database.swift:814` | dentro il contenitore; segue il bundle ID |
| Cache allegati | `MishMailAttachments` nella cartella temporanea | `Support/AttachmentCache.swift:21` | usa e getta |
| Log su file | `Library/Logs/MishMail/diagnostics.log`, `Library/Logs/MishMailRelauncher.log` | `DiagnosticLog.swift:52`, `Relauncher/main.swift:29` | file nuovi; i vecchi restano |
| Sottosistemi di log | `io.github.bateman.MishMail.diag`, `….perf` | `DiagnosticLog.swift:34`, `PerfMetrics.swift:37`, `scripts/perf-capture.sh`, `Makefile` | stringhe libere, non registrate; cambiano i filtri in Console |
| Code di lavoro | `io.github.bateman.MishMail.mcp`, `….diagnostics`, `MishMail.OAuthLoopback`, `mishmail.connectivity` | sorgenti | puramente testuale |
| Regola WebKit | `io.github.bateman.MishMail.block-remote-html-images.v1` | `HTMLRemoteImageBlocker.swift:12` | ricompilata al primo avvio |
| Pasteboard dei test UI | `io.github.bateman.mishmail.uitest.breadcrumbs` | `UITestBreadcrumbs.swift`, `SidebarNavUITests.swift` | i due lati devono cambiare insieme |
| Schema URL | `mishmail://thread/…` (`CFBundleURLSchemes` in `Info.plist`, `GmailWebLinks.swift`, `DeepLinkThreadResolver.swift`, prompt AI) | registrato in LaunchServices | i link `mishmail://` già scritti altrove smettono di aprirsi |
| Nomi dei tipi URL | `$(PRODUCT_BUNDLE_IDENTIFIER).mailto`, `.deeplink` | `Info.plist` | seguono il bundle ID |
| Chiavi Info.plist | `MishMailUpdateChannel`, `MishMailAIFeatures`, `MishMailCalendar`, `MishMailPGP` | `Info.plist`, sorgenti, `Makefile` (`plutil -extract`) | testuale, ma sorgente, plist e `Makefile` devono cambiare insieme |
| Nome del server MCP | `"mishmail"` | `MCP/MCPTools.swift:30` | i client MCP esterni configurati con quel nome vanno aggiornati (funzione spenta) |
| Dominio dei Message-ID | `mishmail.local` | `Gmail/MessageParsing.swift:1383` | solo i messaggi nuovi; quelli già inviati tengono il loro |
| Agente launchd | etichetta `io.github.bateman.mishmail-summarize`, installato a mano dall'utente | `scripts/` | se installato: scaricare il vecchio, caricare il nuovo (funzione AI, spenta) |
| Profilo di notarizzazione | `NOTARY_PROFILE ?= MishMail-notary` | `Makefile:63` | è il nome di una voce nel Keychain del Mac: va ricreata o passata a mano |
| Asset di rilascio | `MishMail-$(VERSION).zip`, titolo "MishMail x.y.z" | `Makefile`, `UpdateChecker.swift` | nessuna release pubblicata dal fork: niente da migrare |
| Identificatori di notifica | l'ID della richiesta, senza nome dell'app | `Support/Notifier.swift` | niente da rinominare |
| Identificatori di accessibilità | 68 in tutto, nessuno con il nome | sorgenti | niente da rinominare |
| Tabelle del database | 23, nessuna con il nome | `Store/Database.swift` | niente da rinominare; nessuna migrazione dello schema |

### 2.5 Impostazioni di build e variabili d'ambiente

Quindici nomi `MISHMAIL_*`, 180 occorrenze in 55 file:

| Nome | Occ. | Che cos'è |
|---|---|---|
| `MISHMAIL_AI_FEATURES` | 24 | interruttore di build (xcconfig → Info.plist) |
| `MISHMAIL_CALENDAR` | 22 | interruttore di build |
| `MISHMAIL_PGP` | 17 | interruttore di build |
| `MISHMAIL_UPDATE_CHANNEL` | 18 | canale dell'updater, vuoto |
| `MISHMAIL_APP_ENTITLEMENTS` | 11 | scelta degli entitlements |
| `MISHMAIL_WARNINGS_AS_ERRORS` | 4 | warning come errori in CI |
| `MISHMAIL_DEMO`, `MISHMAIL_UI_TEST` | 29, 26 | ambiente: dati finti, niente Keychain |
| `MISHMAIL_MCP_TOKEN`, `MISHMAIL_MCP_PORT` | 8, 5 | ambiente degli script MCP |
| `MISHMAIL_PERF`, `MISHMAIL_DEMO_AMPLIFY`, `MISHMAIL_UI_ROW_BUTTONS`, `MISHMAIL_BENCHMARK`, `MISHMAIL_GMAIL_BATCH` | 4, 3, 3, 2, 2 | ambiente di sviluppo e misura |

Tutti gli interruttori sono "spento se assente". Dopo la rinomina, un `Config/Local.xcconfig` non tracciato che usa ancora i nomi vecchi viene ignorato in silenzio: le funzioni restano spente e l'updater inerte. È il lato sicuro, ma il proprietario deve aggiornare il suo file. `MISHMAIL_DEMO` e `MISHMAIL_UI_TEST` decidono se toccare il Keychain e quale database aprire: app e test UI devono cambiare nello stesso commit, altrimenti un test UI partirebbe sul database vero.

### 2.6 "Ask Mish" → "Ask AI"

| Voce | Oggi | Nuova forma |
|---|---|---|
| Tipi e file | `AskMishContext`, `AskMishController`, `AskMishLayout`, `AskMishModelMenu`, `AskMishTools`, `AskMishTrace`, `AskMishPanelView` (4.324 righe) e 5 file di test (1.463 righe) | `AskAI…` |
| Altri file che lo citano | 32, tra cui `ContentView.swift` (29), `MCPBridge.swift` (19), `MailStore.swift` (12), `SettingsView.swift` (9) | testuale |
| Stringhe visibili | "Ask Mish", "Ask Mish…", "Handle with Mish" (19 stringhe) | "Ask AI", "Ask AI…", "Handle with AI" |
| Caso dell'enum | `LLMTask.askMish`, con valore grezzo `"askMish"` | `askAI` |
| Chiavi UserDefaults | `askMish.hostedSpeed`, `askMish.modelIntelligenceFloor`, `askMish.hostedAck.<uuid>`, `llm.task.askMish`, `ollama.think.askMish` | `askAI.…`, `llm.task.askAI`, `ollama.think.askAI` |
| Voce della palette | id `askmish`; ancora di scorrimento `askmish.tail` | `askai`, `askai.tail` |
| Esclusione in `project.yml` | `AskMishController.swift` | `AskAIController.swift` |
| Tabelle del database | `chatConversation`, `chatMessage`, `chatConversationAccount`, `llmUsage`: nessuna porta "mish" | nessun cambio |

Le chiavi salvate non richiedono migrazione se il bundle ID cambia, perché il dominio delle preferenze riparte vuoto. Richiederebbero una migrazione, o il mantenimento dei valori vecchi, solo se si tenesse il bundle ID attuale e qualcuno avesse già usato una build con l'AI accesa. La colonna `llmUsage.task` potrebbe contenere `"askMish"` in un database esistente: non verificato; irrilevante con un database nuovo.

Attenzione nello script: "Mish" compare anche in `mishmish` (`docs/naming.md`, storico) e in `MMResult` (tipo C della libreria, sezione 6.2). La sostituzione va fatta per forme esatte, non per sottostringa.

### 2.7 Stringhe visibili, menu, icona

- 34 stringhe con "MishMail" in `Sources/MishMail/UI` e `App`: "About MishMail", "Support MishMail", testi delle Impostazioni, avvisi. Il titolo della notifica riassuntiva è `"MishMail"` (`NotificationContent.swift:114`).
- 20 chiamate `NSLog("MishMail: …")`: prefisso dei log, citato anche nei casi di prova di `LogHygieneTests`.
- Il nome nella barra dei menu, nel Dock e in "Esci da …" viene da `PRODUCT_NAME` / `CFBundleDisplayName`: cambia da solo.
- Il pannello "About" ha la riga "Support MishMail" che porta a `github.com/sponsors/ronboger`. Rinominata in "Support DreaMail" indirizzerebbe donazioni per DreaMail all'autore dell'originale: va deciso (domanda 4). Lo stesso vale per `.github/FUNDING.yml`.
- **Icona:** `Design/AppIcon.svg` e `AppIcon-closed.svg` sono una busta viola, senza scritte e senza albicocca. Nessun cambio necessario. Le tre schermate in `docs/screenshots/` possono mostrare il vecchio nome nella barra del titolo: da rifare sul Mac.
- `docs/naming.md` spiega il nome con *mishmish* (albicocca): diventa storia, con una sezione nuova per DreaMail.

### 2.8 Makefile, script, CI

- `Makefile`: 74 occorrenze. Percorsi dei prodotti, nomi degli schemi, `pkill -f "MishMail Debug"`, `defaults delete io.github.bateman.MishMail.debug`, `rm -rf /Applications/MishMail.app`, controlli `plutil -extract MishMail…`, `DerivedData/MishMail-*`.
- `scripts/`: 79 occorrenze in 14 file. `scripts/mcp_common.py:13` contiene il percorso del contenitore con il bundle ID. `scripts/update-mishmail.sh` usa `pgrep -qx MishMail` e `osascript -e 'quit app "MishMail"'`.
- `.github/workflows/ci.yml`: una sola occorrenza, in un commento. I nomi dei job ("Workflow hardening", "Changed files", "Unit tests & build", "UI smoke tests") non contengono il nome e **non vanno cambiati**: sono i nomi con cui una regola di protezione del branch riconosce i controlli richiesti.
- `.github/scripts/test_ci_checks.py`: 9 occorrenze in dati di prova (`MishMailTests.FooTests`, un `project.yml` finto).
- Nessun `secrets.` o `vars.` nei workflow; nessun badge nel README.
- La cache di build in CI ha chiave derivata da `hashFiles('project.yml')`: cambia da sola, la prima build dopo la rinomina parte a freddo.
- `.oss-scanner/Dockerfile` e `threat_model.md` citano `ronboger/mishmail`: riferimento all'upstream, da tenere com'è o aggiornare dove parla del fork.

### 2.9 Updater e rilasci

L'updater è spento (canale vuoto, DEC-009). Il codice che porta il nome: `MishMailUpdateChannel`, il commento su `MishMail-*.zip.sha256`, `scripts/update-mishmail.sh`, i test `UpdateScriptTests` e `UpdateBundleIdentifierTests`. `UpdateChecker` rifiuta un aggiornamento con bundle ID diverso da quello in esecuzione (`bundleIdentifierMismatch`): se un giorno l'updater venisse acceso, una versione "MishMail" non potrebbe aggiornarsi a "DreaMail" da sola. Oggi non riguarda nessuno, perché il fork non ha release (verificato con l'API di GitHub il 25 novembre 2026).

## 3. Che cosa perde un'installazione esistente

Fonti Apple lette il 25 novembre 2026. Dove manca una fonte è scritto.

| Voce | Legata a | Con il bundle ID nuovo | Migrazione al primo avvio |
|---|---|---|---|
| Contenitore sandbox (database cifrato `mail.sqlite`, `mcp.json`, cartella temporanea) | bundle ID e firma | contenitore nuovo e vuoto; il vecchio resta | non con un meccanismo Apple: `container-migration.plist` copre il passaggio da app non in sandbox ad app in sandbox, non quello fra due contenitori [A1][A2] |
| Dati solo locali nel database: firme (DEC-055), bozze locali, invii programmati, operazioni in coda, viste salvate, VIP, mittenti bloccati, conversazioni e riepiloghi AI | file nel contenitore | non visibili alla nuova app | solo copiando il database **e** la sua chiave |
| Posta, label, thread | Gmail | risincronizzati | non serve |
| Chiave del database (`db.key`) | Keychain, servizio = bundle ID | la nuova app cerca sotto il servizio nuovo, non la trova e ne genera una nuova | possibile leggendo il servizio vecchio, con una richiesta di macOS all'utente [A4] |
| Token di accesso Google (`refreshToken.<email>`), token Calendar, `oauth.clientSecret` | Keychain, come sopra | non trovati: l'utente accede di nuovo | come sopra; in alternativa si accede di nuovo |
| Chiavi private OpenPGP | non ancora salvate (archivio previsto nella PR #68) | niente da perdere oggi | — |
| Preferenze (`oauth.clientID`, scorciatoie, colore, lingue, ecc.) | dominio UserDefaults = bundle ID, nel contenitore | valori predefiniti | copiabili solo da fuori dall'app |
| Posizione della finestra | UserDefaults, sotto il nome di salvataggio [A8] | persa | la PR #65 introduce il nome `MishMailMainWindow`: conviene rinominarlo prima che sia usato |
| Permesso notifiche | non documentato da Apple; ci si aspetta per bundle ID | richiesta di nuovo | no |
| Client e-mail predefinito (`mailto:`) | LaunchServices; legame con il bundle ID non verificato su una pagina Apple | da reimpostare nelle Impostazioni | no |
| Permessi TCC | requisito designato del codice, che contiene il bundle ID [A5] | l'app non dichiara usi protetti (nessuna chiave `NS…UsageDescription`); restano solo i file scelti dall'utente | — |
| Login Items | l'app non usa `SMAppService` | niente | — |
| Identità di firma e requisito designato | firmatario + identificatore [A5] | requisito nuovo: è la causa delle richieste del Keychain | — |
| Agente launchd dei riepiloghi | file installato a mano | il vecchio punta a script e percorsi vecchi | scaricare e ricaricare a mano |

Dettagli che contano:

1. **Keychain.** `Keychain.swift` non usa `kSecUseDataProtectionKeychain`, e gli entitlements non hanno `keychain-access-groups`: secondo TN3137 gli elementi vanno nel Keychain su file, con liste di controllo d'accesso [A3]. Il README conferma la pratica (`security delete-generic-password -s …`). L'accesso è legato al requisito designato dell'app che ha creato l'elemento; se il requisito cambia, macOS mostra una finestra di autorizzazione [A4]. Il caso "stesso team, bundle ID diverso, app in sandbox" non è descritto esplicitamente in una fonte Apple: va provato sul Mac.
2. **Contenitore di un'altra app.** Da macOS 14 l'accesso ai dati di un'altra app chiede il consenso, salvo che le due app abbiano lo stesso Team ID [A6]. Se una nuova app *in sandbox* possa leggere il vecchio contenitore senza una scelta esplicita dell'utente non è stato verificato. Una migrazione fatta dall'app passerebbe quindi da un pannello di selezione della cartella; una fatta da Terminale no.
3. **Firma ad hoc.** Con la firma ad hoc non c'è un'identità stabile: Keychain e contenitore si comportano male a ogni ricompilazione, rinomina o no [A5][A7]. Il `Makefile` rifiuta già un'installazione ad hoc.
4. **Solo il nome visibile.** Cambiando `PRODUCT_NAME` e il nome dell'app ma non il bundle ID, il requisito designato non cambia (contiene firmatario e identificatore, non il nome né il percorso [A5]), quindi contenitore, Keychain e preferenze restano validi. È una deduzione: Apple non lo scrive in modo esplicito per la rinomina.

Se si vogliono conservare i dati locali, la via praticabile è uno script da Terminale sul Mac del proprietario, fuori dall'app: copia la cartella `Application Support/MishMail` nel nuovo contenitore, esporta e importa le preferenze con `defaults`, ricrea gli elementi del Keychain sotto il servizio nuovo con `security`. Costa circa una giornata in più, si può provare solo su quel Mac e sposta materiale segreto con uno strumento a riga di comando. Non lo raccomando, salvo risposta diversa alla domanda 2.

## 4. Lato Google

Fonti lette il 25 novembre 2026.

- Ogni utente usa il proprio progetto Google Cloud con un client OAuth di tipo "Desktop app". Per questo tipo la console chiede solo un nome: nessun bundle ID, nessun nome di app (a differenza del tipo iOS) [G1].
- Il reindirizzamento è su `http://127.0.0.1:<porta>/oauth2/callback`. Il loopback resta supportato per le app desktop macOS [G2]. Se la porta vada registrata non è chiarito dalla documentazione: oggi funziona senza.
- **La rinomina non richiede alcuna modifica in Google Cloud Console.** Client ID e client secret restano gli stessi.
- Facoltativo: cambiare il nome del progetto e il nome dell'app nella schermata di consenso (oggi il README suggerisce "MishMail"). In stato "Testing" non c'è verifica. Per un'app verificata in produzione il cambio di nome viene salvato come bozza e richiede una nuova verifica del marchio [G3]. Che il cambio di nome non invalidi i token esistenti non è scritto da nessuna parte; l'elenco ufficiale delle cause di invalidazione non lo include [G4].
- L'accesso ripetuto dopo il cambio di bundle ID dipende dal Keychain, non da Google: i token sono legati al client ID, che non cambia [G4].
- In stato "Testing" con ambito `gmail.modify` i token scadono comunque dopo 7 giorni, con un massimo di 100 utenti di prova [G4][G5]. Accedere di nuovo è già un'operazione abituale.
- Per il futuro: una distribuzione con client condiviso richiede verifica del marchio e valutazione di sicurezza CASA annuale per l'ambito ristretto [G6]. Le regole sul nome chiedono che rappresenti l'app e non si confonda con i marchi di Google o di altri [G3]; nessuna pagina letta tratta un nome che contiene solo "Mail".

## 5. Lato GitHub

Fonti lette il 25 novembre 2026.

### 5.1 Rinomina di `bateman/mishmail` in `bateman/dreamail`

- **Che cosa viene reindirizzato:** il traffico web e `git clone`, `fetch`, `push` verso il vecchio indirizzo [H1]. La documentazione elenca issue, wiki, stelle e follower fra ciò che segue il repository. Per PR, regole di protezione, cronologia e cache di Actions non c'è un elenco voce per voce: la rinomina non crea un repository nuovo, quindi ci si aspetta che restino, ma non è documentato.
- **Limiti:** il reindirizzamento cessa se si crea un nuovo repository con il vecchio nome. Le chiamate `uses:` a un'action ospitata in un repository rinominato non vengono reindirizzate (il repository non ospita action). Gli URL di GitHub Pages non vengono reindirizzati (Pages non è attivo) [H1]. Il reindirizzamento dell'API REST non è confermato per le rinomine.
- **Rapporto con l'upstream:** secondo l'API di ricerca di GitHub, interrogata il 25 novembre 2026, `bateman/mishmail` ha `fork: false`. Per GitHub non è un fork di `ronboger/mishmail`, quindi non c'è una rete di fork da cui staccarsi. Il legame con l'upstream è solo nella storia git e nei testi. Da confermare nella pagina del repository (assenza della dicitura "forked from"). Se invece fosse un fork: può avere un nome diverso dall'originale, e lo sgancio ("Leave fork network") è permanente [H2].
- **Che cosa aggiornare:** la descrizione del repository ("A local-native, ultra-fast mail app for Mac") non contiene il nome. I cloni esistenti: `git remote set-url origin https://github.com/bateman/dreamail.git` [H1]. Nel codice `github.com/bateman/mishmail` compare in 3 file (`UpdateChannelTests.swift`, `UpdateScriptTests.swift`, `registro-decisioni.md`), sempre come testo.
- **Sessioni cloud:** l'accesso delle sessioni è concesso per nome di repository. Che una sessione aperta continui a leggere e scrivere dopo la rinomina non è verificato. Conviene rinominare senza sessioni attive e aprirne di nuove dopo.
- **Segreti, release, badge:** nessun segreto usato dai workflow, nessuna release, nessun badge.
- **Scelta del nome:** `dreamail` in minuscolo, come `dreamail-openpgp`. Su GitHub esistono `RoganMurley/dreamail` (5 stelle, fermo dal 2016) e `maccman/dreamail` (fermo dal 2010): nessun conflitto tecnico, perché il nome è per proprietario.

### 5.2 Libreria `bateman/dreamail-openpgp`

Il repository ha già il nome giusto; dentro, il vecchio nome compare 61 volte (`MishMail` 38 in 14 file, `mishmail` 20 in 9, `MISHMAIL` 3), più 36 `mm_` e 37 tipi `MM…`. Con le decisioni prese:

| Voce | Oggi | Nuova forma |
|---|---|---|
| Prodotto e target SwiftPM | `MishMailRPGP` | `DreaMailRPGP` |
| Modulo (`module.modulemap`) | `module MishMailRPGP` | `module DreaMailRPGP` |
| Header | `rust/include/mishmail_rpgp.h` | `rust/include/dreamail_rpgp.h` |
| Simboli C | `mm_pgp_verify_detached`, `mm_pgp_verify_cleartext`, `mm_pgp_decrypt`, `mm_pgp_inspect_keys`, `mm_pgp_import_public`, `mm_pgp_import_secret`, `mm_pgp_free` | `dm_pgp_*` |
| Tipi C | `MMResult` e simili | `DMResult` (conseguenza del prefisso; da confermare) |
| Crate Rust | `mishmail-rpgp`, libreria `libmishmail_rpgp.a` | `dreamail-rpgp`, `libdreamail_rpgp.a` |
| Asset di rilascio | `MishMailRPGP.xcframework.zip` | `DreaMailRPGP.xcframework.zip` |
| Controllo dei simboli in `build-xcframework.sh` | cerca `mm_pgp_…` in `mishmail_rpgp.h` | deve cercare `dm_pgp_…` nel nuovo header |
| Nome del pacchetto, licenza, URL | `dreamail-openpgp` | invariati |

Costo: i simboli cambiano, quindi l'interfaccia binaria è incompatibile. Servono, in ordine: una PR nella libreria; il rilascio `v0.2.0` con il workflow "Release" (DEC-059), che produce uno zip nuovo con **checksum nuovo**; il commit che scrive versione e checksum in `Package.swift`; nell'app, il **nuovo commit fissato** in `project.yml` insieme a `import DreaMailRPGP` e alle 7 chiamate `dm_pgp_*` in `PGP/RPGPEngine.swift`. Il checksum registrato in `docs/DEPENDENCIES.md` va aggiornato con la procedura lì descritta. La release `v0.1.0` resta pubblicata, quindi `main` continua a compilare finché non passa al nuovo commit, e si può tornare indietro. Ordine di grandezza: mezza giornata più il tempo del workflow.

Su `main` la libreria non è ancora collegata: la collega la PR #68, che fissa `MishMailRPGP` al commit `adad8a1`.

## 6. Controlli di guardia

Vanno aggiornati senza indebolirli. Nessuno va disattivato, e nessun test va saltato per ottenere la CI verde.

| Controllo | Che cosa afferma oggi sul nome | Come deve affermare quello nuovo |
|---|---|---|
| `ForkIdentityTests` | I tre bundle ID di `project.yml` sono esattamente `io.github.bateman.MishMail`, `.debug`, `.Relauncher`. `Relaunch.bundleID` coincide con quello Release. Il prefisso upstream `dev.ronboger` non compare in `Sources`, `Tests`, `scripts`, `Config`, `Makefile`, `project.yml`. `Info.plist` (in `Sources/MishMail/`) inoltra `$(MISHMAIL_UPDATE_CHANNEL)`, lo xcconfig lo lascia vuoto e `project.yml` non lo imposta. | Stessi tre controlli con i nuovi ID e il nuovo percorso. Lo scan sul prefisso upstream resta identico. Da **aggiungere**: lo stesso scan per il vecchio ID del fork e per `MISHMAIL_UPDATE_CHANNEL`, così che un nome vecchio rimasto in un punto non lasci un interruttore senza effetto. |
| `RemovedProductReferenceTests` | Non riguarda il nome MishMail: vieta il ritorno del prodotto escluso con DEC-012 in `Sources`, `Tests`, `scripts`, `.github`, `Config`, `Design` e nei documenti di primo livello. Dipende dal nome solo per un percorso (`Sources/MishMail/Support/Colors.swift`), usato per provare che lo scan vede i sorgenti. | Cambia solo il percorso. Il test deve fallire se la cartella non esiste: non sostituire il controllo con uno che passa a vuoto. È il modello per un controllo nuovo sul vecchio nome (sotto). |
| `LogHygieneTests` | Scansiona `Sources/` e vieta di registrare descrizioni di errore o identificatori. I casi di prova usano il prefisso `NSLog("MishMail: …")` e un percorso di contenitore con il bundle ID; un test legge `Sources/MishMail/Support/SafeTextLayout.m`; richiede più di 50 file sotto `Sources`. | Prefisso e percorsi nuovi nei casi di prova. Le regole di scansione non dipendono dal nome e restano uguali. La soglia dei 50 file resta. |
| `.github/test-skip-allowlist.txt` | Due test `HTMLBodyHeightLoopTests.…`, scritti senza nome del modulo. `check-test-skips.py` accetta qualunque prefisso di modulo. | Nessun cambio. L'elenco non va allungato per far passare la rinomina. Cambiano solo i dati di prova in `test_ci_checks.py`. |
| Job "Workflow hardening" | Esegue `check-workflows.py`, `check-package-pins.py`, `make script-tests`, `make shellcheck`. Nessuno contiene il nome, salvo i dati di prova. | Il nome del job resta identico. Gli script rinominati devono restare coperti da `shellcheck` e dai test degli script. |
| `check-package-pins` | Ogni pacchetto di `project.yml` ha solo `url` e `revision` a 40 cifre esadecimali. Il nome del pacchetto è libero (`[A-Za-z0-9_-]+`). | Nessun cambio allo script. La voce `DreaMailRPGP` deve passare così com'è; il nuovo commit della libreria va registrato in `docs/DEPENDENCIES.md`. |
| Controlli di `make install` / `make release` | Rifiutano se l'app compilata non ha `MishMailAIFeatures`, `MishMailCalendar`, `MishMailPGP` con il valore tracciato, o se il relauncher manca o è in sandbox. | Chiavi e percorsi nuovi, nello stesso commit di `Info.plist` e dei sorgenti. Se disallineati rifiutano: è il comportamento voluto. |

**Controllo nuovo proposto:** un test, sul modello di `RemovedProductReferenceTests`, che vieti il ritorno di "MishMail", "mishmail", "MISHMAIL_" e "Mish" nell'albero del prodotto, con un elenco esplicito e corto di eccezioni (sezione 7). Senza di esso la rinomina si degrada alla prima PR scritta su una base vecchia.

## 7. Licenza e attribuzione

Informazioni per il proprietario, non un parere legale.

- La licenza è MIT, con "Copyright (c) 2026 Ron Boger" (`LICENSE`). Chiede una cosa sola: che la nota di copyright e il testo del permesso restino in tutte le copie o parti sostanziali del software. **La riga di copyright di Ron Boger resta.** Si può aggiungere una seconda riga per le modifiche del fork.
- La licenza non obbliga a mantenere il nome "MishMail" né a citare il progetto originale oltre la nota di copyright. Citarlo resta corretto e utile: una riga nel README ("DreaMail deriva da MishMail di Ron Boger") e nel pannello About.
- Il nome "MishMail" è dell'upstream: smettere di usarlo per il fork riduce la confusione fra i due prodotti.
- `README.md:441` ("[MIT](LICENSE) © 2026 Ron Boger") resta, eventualmente con l'aggiunta del fork.
- La libreria `dreamail-openpgp` ha già licenza e copyright propri e l'elenco delle licenze di terze parti: nessun cambio.

Dove il vecchio nome deve restare:

| Dove | Perché |
|---|---|
| Storia git, titoli di PR e issue già chiusi | non si riscrive |
| `CHANGELOG.md`, voci già pubblicate | storia dei rilasci; si aggiunge una voce "rinominato da MishMail" |
| `docs/codex-reviews/`, `docs/plans/`, `docs/superpowers/`, `reviews/`, `docs/security-review*.md` | archivi datati |
| `docs/registro-decisioni.md`, `docs/piano-sviluppo.md`: decisioni e step già registrati | storia; si aggiunge una decisione nuova |
| `docs/naming.md` | storia della scelta precedente; si aggiunge DreaMail |
| Riferimenti all'upstream: `ronboger/mishmail`, `dev.ronboger.MishMail`, la sezione del README "Coming from an upstream install" | descrivono un altro prodotto, che si chiama ancora così |
| Una nuova sezione del README "Coming from a MishMail install" | istruzioni per rimuovere il vecchio contenitore e i vecchi elementi del Keychain |
| `ForkIdentityTests` e il controllo nuovo | devono nominare ciò che vietano (composto a pezzi, come già fanno) |
| Tag `v0.1.0` e relativo asset di `dreamail-openpgp` | rilascio già pubblicato |

## 8. Controllo sul nome "DreaMail"

Ricerca web del 25 novembre 2026. Informazioni, non un parere legale.

| Che cosa | Esito | Fonte | Rilevanza |
|---|---|---|---|
| "DreamMail", client e-mail gratuito per Windows (DreamMail Team) | Stessa categoria, una lettera di differenza; terzi lo scrivono a volte "Dreamail". Dato per abbandonato; ancora scaricabile da siti terzi | https://www.ghacks.net/2012/07/10/dreammail-email-client-review/ · https://portablefreeware.com/index.php?id=863 · https://filehorse.com/download-dreammail | alta |
| Marchio USA DREAMMAIL, reg. 3354048 | Attivo; titolare Alliance Data Systems; classe 35, servizi di marketing; la parte in classe 42 è cancellata | https://tsdr.uspto.gov/statusview/sn78852749 | media |
| Domanda USA DREAMMAIL di DreamHost, classi 38 e 42 | Decaduta | https://tsdr.uspto.gov/statusview/sn86551522 | media |
| Altre due domande USA (DREAM MAIL, DREAMMAIL) | Decadute | https://tsdr.uspto.gov/statusview/sn75880423 · https://tsdr.uspto.gov/statusview/sn75919821 | bassa |
| `dreamail.com` | Registrato dal 2003; contenuto non visibile | https://rdap.org/domain/dreamail.com | media |
| `dreamail.org` | Registrato il 5 novembre 2026 da soggetto ignoto; non risponde | https://rdap.org/domain/dreamail.org | media |
| `dreamail.net` | Registrato dal 2022; non risponde | https://rdap.org/domain/dreamail.net | bassa |
| `dreammail.eu`, `dreammail.org`, `dreammail.com` | Pagina generica; registrato; in vendita | https://www.dreammail.eu/ · https://rdap.org/domain/dreammail.org · https://dreammail.com/ | bassa |
| GitHub | `RoganMurley/dreamail` (5 stelle, 2016), `maccman/dreamail` (2010), altri inattivi | API di ricerca di GitHub | bassa |
| npm, PyPI, Homebrew | `dreamail` libero | https://registry.npmjs.org/dreamail · https://pypi.org/pypi/dreamail/json · https://formulae.brew.sh/api/cask/dreamail.json | bassa |
| App Store iOS (USA), Google Play | Nessuna app con quel nome | https://itunes.apple.com/search?term=dreamail&entity=software · https://play.google.com/store/search?q=dreamail&c=apps | bassa |

**Non verificato:**

- EUIPO, TMview e WIPO Global Brand Database: non raggiungibili da qui. Nessun dato su marchi UE, internazionali o cinesi.
- Ricerca libera USPTO: non eseguibile; un deposito "DREAMAIL" esatto negli USA non si può escludere.
- Mac App Store e store di altri paesi.
- `dreamail.app`, `.io`, `.dev`, `.email`: stato ignoto.
- Esistenza di un utente o organizzazione GitHub `dreamail`.
- Se il produttore di DreamMail distribuisca ancora versioni.
- Un risultato del registro dei marchi del Regno Unito apparso nella ricerca (https://www.ipo.gov.uk/t-tmj/tm-journals/2026-021/UK00004369591.html): pagina non leggibile, marchio ignoto.

**Valutazione.** La grafia esatta "Dreamail" non risulta usata da un prodotto. Il rischio concreto è la vicinanza a "DreamMail", client e-mail noto e fermo: probabili confusione nelle ricerche e refusi. Prima di un lancio pubblico vanno fatte a mano le ricerche su EUIPO, TMview e WIPO, e controllati i domini `.app` e `.dev`. `docs/naming.md` chiede lo stesso controllo per qualunque nome.

## 9. Forme da usare

Decise:

| Contesto | Forma |
|---|---|
| Nome del prodotto, tipi Swift, target, file | `DreaMail`, `DreaMailApp`, `DreaMailTests`, `DreaMailUITests`, `DreaMailRelauncher` |
| Bundle ID | `io.github.bateman.DreaMail`, `.debug`, `.Relauncher` |
| Percorsi minuscoli, URL, schema, script | `dreamail`, `dreamail://`, `scripts/update-dreamail.sh` |
| Build e ambiente | `DREAMAIL_AI_FEATURES`, `DREAMAIL_DEMO`, ecc. |
| Chiavi Info.plist | `DreaMailAIFeatures`, `DreaMailCalendar`, `DreaMailPGP`, `DreaMailUpdateChannel` |
| Libreria | target `DreaMailRPGP`, simboli `dm_pgp_*`, header `dreamail_rpgp.h` |
| Assistente | "Ask AI", `AskAI…`, `askAI` |

Derivate, da confermare con un sì (domanda 5):

| Voce | Proposta |
|---|---|
| Repository | `bateman/dreamail` |
| Prefisso dei log | `NSLog("DreaMail: …")` |
| Sottosistemi di log | `io.github.bateman.DreaMail.diag`, `.perf` |
| Cartella dati | `Application Support/DreaMail` (`DreaMailDemo`, `DreaMailUITests`) |
| Dominio dei Message-ID | `dreamail.local` |
| Nome del server MCP | `dreamail` |
| Etichetta launchd | `io.github.bateman.dreamail-summarize` |
| Tipi C della libreria | `DMResult` |
| Crate Rust | `dreamail-rpgp` |
| "Handle with Mish" | "Handle with AI" |

## 10. Piano

### 10.1 Opzioni

| | A. Tutto insieme, senza migrazione | B. Tutto insieme, con script di migrazione | C. A tappe: nome visibile ora, bundle ID dopo |
|---|---|---|---|
| Che cosa cambia | tutto, bundle ID compresi | come A, più uno script sul Mac | tutto tranne bundle ID e ciò che ne dipende |
| Dati dell'installazione | si riparte: accesso e risincronizzazione; i dati solo locali si reinseriscono | conservati, se lo script funziona | conservati |
| Rischio | basso: il vecchio resta intatto | medio: copia di chiavi e database fuori dall'app, provabile solo sul Mac | basso ora; il vecchio nome resta in contenitore, Keychain e README, oppure lo strappo è solo rinviato |
| Lavoro | 2–3 giorni | 3–4 giorni | 2 giorni ora, più 1–2 dopo |
| Ritorno indietro | reinstallare la vecchia build: dati e chiavi sono ancora lì | come A, se lo script copia e non sposta | revert della PR |
| Nomi vecchi residui | nessuno fuori dagli archivi | nessuno | bundle ID, servizio Keychain, percorso del contenitore |

### 10.2 Raccomandazione: opzione A

Motivi: un'installazione sola; la posta è una copia di Gmail; l'accesso ripetuto è già routine ogni 7 giorni in stato "Testing"; il precedente dello step 1A; il vecchio contenitore resta come copia di sicurezza. L'opzione C non completa il rebranding richiesto e costa due giri di review invece di uno. L'opzione B conviene solo se i dati locali sono molti (domanda 2).

### 10.3 Ordine dei lavori

0. **Prima di iniziare.** Risposte alle domande della sezione 11. Controllo dei marchi a mano. Chiudere le PR aperte: #63 (30 file), #65 (5 file), #68 (40 file). Una rinomina che sposta 636 file va in conflitto con ogni PR aperta; farla a `main` fermo evita di riscrivere tre branch. Nessun'altra sessione al lavoro in quei giorni.
1. **Libreria.** PR in `dreamail-openpgp`, rilascio `v0.2.0`, commit con versione e checksum (sezione 5.2). L'app non cambia ancora.
2. **PR di rinomina nell'app**, una sola, livello standard (tocca CI, identificatori di archiviazione, firma). Generata da uno script di sostituzioni esatte e spostamenti, con l'elenco delle esclusioni della sezione 7; lo script va nel testo della PR, così la review controlla le regole e le eccezioni invece di 1.500 righe. Contiene: spostamenti dei file, `project.yml`, `Makefile`, xcconfig, `Info.plist`, sorgenti, test, script, CI, documenti vivi, nuovo commit fissato della libreria, controlli di guardia aggiornati, controllo nuovo sul vecchio nome, sezione del README per chi viene da MishMail, decisione nuova nel registro.
3. **Rinomina del repository** da parte del proprietario (Settings → General), subito dopo il merge. Poi `git remote set-url` nei cloni e sessioni nuove. Non creare mai un altro repository `bateman/mishmail`.
4. **Sul Mac.** Aggiornare `Config/Local.xcconfig` ai nomi `DREAMAIL_…`. `make clean`, `make install`. Inserire client ID e secret, accedere agli account, attendere la sincronizzazione. Reimpostare client predefinito, notifiche e firme. Ricreare il profilo di notarizzazione se usato.
5. **Pulizia, dopo qualche giorno d'uso.** Rimuovere `/Applications/MishMail.app`, i due contenitori `io.github.bateman.MishMail*` e i vecchi elementi del Keychain, con i comandi documentati nel README sul modello di quelli già presenti per l'upstream. Rifare le schermate.

### 10.4 Come verificare

Che cosa prova la CI:

- compilazione di app, relauncher e test con warning come errori: ogni riferimento mancato a un tipo o a un percorso è un errore di build;
- test di unità, compresi `ForkIdentityTests`, `LogHygieneTests`, `RemovedProductReferenceTests` e il controllo nuovo;
- test degli script e `shellcheck`;
- nessun test saltato oltre ai due già ammessi;
- test UI: girano solo su release o avvio manuale. Vanno lanciati a mano una volta sul branch (`make ui-test-ci`), perché usano le variabili `…_DEMO` e `…_UI_TEST` e il nome della pasteboard.

Le sessioni cloud non compilano Swift: servono alcuni giri di CI, due o quattro è una stima.

Che cosa prova solo il Mac del proprietario:

- firma con il team personale e controlli di `make install`;
- creazione del nuovo contenitore e nessuna richiesta inattesa del Keychain;
- accesso a Google, sincronizzazione, invio di un messaggio;
- notifiche, `mailto:` come client predefinito, link `dreamail://`;
- nome corretto in Dock, barra dei menu, About e Impostazioni;
- convivenza con la vecchia app finché non viene rimossa;
- se in uso: agente launchd, script MCP, notarizzazione.

Controllo finale nel repository: `git grep -il mishmail` deve restituire solo i percorsi della sezione 7.

### 10.5 Come tornare indietro

- Prima della rinomina del repository: revert della PR.
- Dopo: il repository si può rinominare di nuovo; i reindirizzamenti valgono nei due sensi finché nessuno riusa il nome.
- Sul Mac: reinstallare la build precedente. Contenitore e Keychain vecchi sono intatti fino al passo 5. Il passo 5 è il solo irreversibile.
- Libreria: `v0.1.0` resta pubblicata; basta rimettere il vecchio commit fissato.

### 10.6 Quando

Il momento migliore è subito dopo il merge della PR #68 e prima che parta la prossima ondata di lavoro. Aspettare costa: ogni PR nuova aggiunge occorrenze del nome e ogni branch aperto diventa un conflitto. Se la #68 dovesse tardare molto, l'alternativa è rinominare prima la libreria e far nascere la #68 già sui nomi nuovi; resterebbe però da riscrivere il suo branch dopo la rinomina dell'app.

## 11. Domande per il proprietario

1. Confermi l'opzione A (tutto insieme, bundle ID compresi, nessuna migrazione automatica, accesso da rifare)?
2. Nell'installazione attuale ci sono dati solo locali che non vuoi reinserire a mano (firme, viste salvate, VIP, mittenti bloccati, bozze locali, invii programmati)? Se sì, serve lo script dell'opzione B.
3. Oltre al tuo Mac esistono altre installazioni della build `io.github.bateman.MishMail`, o altri cloni del repository?
4. La riga "Support MishMail" nel pannello About e `.github/FUNDING.yml` puntano alle donazioni per Ron Boger. Vanno tolti, lasciati come "sostieni il progetto originale", o sostituiti con i tuoi?
5. Confermi le forme derivate della sezione 9: repository `bateman/dreamail`, cartella dati `DreaMail`, `dreamail.local`, server MCP `dreamail`, `DMResult`, crate `dreamail-rpgp`, "Handle with AI"?
6. Vuoi aggiungere una riga di copyright tua in `LICENSE`, accanto a quella di Ron Boger che deve restare?
7. Le PR #63, #65 e #68 si chiudono prima della rinomina, o la rinomina ha la precedenza e i tre branch si riscrivono dopo?
8. `bateman/mishmail` risulta non essere un fork per GitHub (`fork: false`). Lo confermi dalla pagina del repository?
9. Fai tu a mano il controllo dei marchi su EUIPO, TMview e WIPO e dei domini `.app` e `.dev` prima di partire, o si procede e si ricontrolla prima di un lancio pubblico?
10. Hai sul Mac un profilo di notarizzazione `MishMail-notary` o l'agente launchd dei riepiloghi installato?

## Fonti

Tutte lette il 25 novembre 2026. Le pagine sono state lette tramite ricerca web e riassunte; le citazioni vanno ricontrollate prima di un uso pubblico.

Apple

- [A1] Accessing files from the macOS App Sandbox — https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
- [A2] Migrating your app's files to its App Sandbox container — https://developer.apple.com/documentation/security/migrating-your-app-s-files-to-its-app-sandbox-container
- [A3] TN3137, On Mac keychain APIs and implementations — https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
- [A4] Forum Apple, risposte di un ingegnere DTS su ACL del Keychain e requisito designato — https://developer.apple.com/forums/thread/109517 · https://developer.apple.com/forums/thread/696956 · https://developer.apple.com/forums/thread/730043
- [A5] TN3127, Inside Code Signing: Requirements — https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
- [A6] WWDC23, "What's new in privacy" — https://developer.apple.com/videos/play/wwdc2023/10053/ · `NSAppDataUsageDescription` — https://developer.apple.com/documentation/bundleresources/information-property-list/nsappdatausagedescription
- [A7] Forum Apple, contenitore e cambio di bundle ID — https://developer.apple.com/forums/thread/741479 · https://developer.apple.com/forums/thread/721701
- [A8] `NSWindow.setFrameAutosaveName(_:)` — https://developer.apple.com/documentation/appkit/nswindow/setframeautosavename(_:) · UserDefaults — https://developer.apple.com/documentation/foundation/userdefaults
- Bundle ID senza registrazione per app fuori dall'App Store e senza entitlement ristretti — https://developer.apple.com/forums/thread/750645
- Sottosistemi di log — https://developer.apple.com/documentation/os/generating-log-messages-from-your-code

Google

- [G1] Manage OAuth Clients — https://support.google.com/cloud/answer/15549257
- [G2] OAuth 2.0 for iOS & Desktop Apps — https://developers.google.com/identity/protocols/oauth2/native-app
- [G3] Manage OAuth App Branding — https://support.google.com/cloud/answer/15549049 · Brand verification — https://developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification · https://support.google.com/cloud/answer/13464018
- [G4] Using OAuth 2.0 to Access Google APIs (scadenza e invalidazione dei token) — https://developers.google.com/identity/protocols/oauth2
- [G5] Manage App Audience — https://support.google.com/cloud/answer/15549945
- [G6] Verifica e ambiti ristretti — https://support.google.com/cloud/answer/13464321 · https://support.google.com/cloud/answer/13465431 · https://support.google.com/cloud/answer/13464323

GitHub

- [H1] Renaming a repository — https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository · Managing remote repositories — https://docs.github.com/en/get-started/getting-started-with-git/managing-remote-repositories
- [H2] Detaching a fork — https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/detaching-a-fork · Fork a repo — https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/fork-a-repo
