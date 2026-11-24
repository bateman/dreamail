# Piano di sviluppo a step

Ultimo aggiornamento: 24 novembre 2026
Riferimento: [Registro delle decisioni](registro-decisioni.md) v0.7 (finding F-xx, decisioni DEC-xxx).

Decisioni prese per questo piano:

- Le funzioni AI e il server MCP vengono disattivati per il momento, senza cancellare codice.
- F-01 viene segnalato in privato all'upstream dal proprietario del fork.
- L'orchestratore è autorizzato a fare il merge su `main` di `bateman/mishmail` quando CI e review sono a posto.

## Flusso per ogni step

1. Una sessione dedicata (Opus 5.5, impegno medio) implementa lo step su un branch descrittivo, senza "claude" nel nome.
2. La sessione apre subito una PR in bozza verso `bateman/mishmail` (mai verso l'upstream), perché la CI gira solo su PR, push a `main` o avvio manuale.
3. Lo step termina con una nuova suite di test (unità, mock, integrazione) superata in CI. Ogni test di regressione deve fallire sul codice precedente alla correzione.
4. A CI verde la sessione avvisa l'orchestratore, che lancia in parallelo `ponytail-review` a livello ultra e `security-audit`. I due report tornano alla sessione per la risoluzione.
5. A correzioni fatte e CI di nuovo verde la sessione marca la PR come pronta. L'orchestratore controlla il diff delle correzioni e decide: merge oppure rinvio alla sessione. Al massimo due giri; bloccano solo i difetti seri.
6. Dopo ogni merge i branch ancora aperti si riallineano a `main` e rifanno la CI.

Limiti noti: la CI non copre Keychain, firma, notarizzazione, Gmail reale né i test UI (che girano solo su release o avvio manuale). Le sessioni cloud sono Linux e non possono compilare Swift: i test girano solo sul runner macOS.

## Passo 0 — base (orchestratore)

☑ GitHub Actions attivo sul fork.
☑ CI verde su `main` a `18294fa` (run n. 1, secondo tentativo). Al primo tentativo è fallito `ComposeBodyCaretScrollTests.testScrolledEditorFollowsTheCaretImmediately`, passato al rilancio senza modifiche: test instabile, affidato allo step 1F.
☐ Merge del registro v0.7 e di questo piano.
☑ Decisione GO su MishMail come base (proprietario, 23 novembre 2026).

## Ondata 1 — in parallelo, file disgiunti

| Step | Contenuto | Finding | File principali |
|---|---|---|---|
| 1A | Identità del fork (bundle ID, nome, canale) e updater disabilitato | F-01 (mitigazione), F-07, DEC-009 | `project.yml`, `Support/UpdateChecker.swift`, `scripts/update-mishmail.sh` |
| 1B | Database legacy fail-closed | F-02 | `Store/Database.swift` |
| 1C | Privacy dei log diagnostici | F-03 | `Support/DiagnosticLog.swift` |
| 1D | Limiti sul listener OAuth | F-09 | `Auth/OAuth.swift` |
| 1E | CI: permessi minimi, action fissate a SHA | F-10 | `.github/workflows/ci.yml` |
| 1F | Rendere deterministico il test instabile dello scorrimento del cursore in composizione, senza saltarlo né disattivarlo | — | `Tests/MishMailTests/ComposeBodyCaretScrollTests.swift` |

## Ondata 1 — esito

Chiusa il 24 novembre 2026: sei PR unite su `main` (#2–#7), ciascuna dopo CI verde, due review (`ponytail-review` ultra e `security-audit`) e un giro di correzioni. Nessuna review ha trovato difetti bloccanti; ogni PR ha ricevuto correzioni obbligatorie prima del merge.

| Finding | Stato dopo l'ondata 1 |
|---|---|
| F-01 | Mitigato e applicato nel codice: updater inerte senza canale, e comunque spento su una copia senza Team ID. La regola di fiducia originale va riprogettata prima di configurare un canale di rilascio. |
| F-02 | Chiuso per la riservatezza. Il comportamento con un vero database legacy va provato su Mac. |
| F-03 | Chiuso per `DiagnosticLog`. Restano altri punti di log (step 2D). |
| F-07 | Chiuso. |
| F-09 | Chiuso. Residuo dichiarato: una raffica di connessioni locali può ritardare l'accesso, non intercettarlo. |
| F-10 | Chiuso per la CI. Resta il pin della dipendenza GRDB (step 2C). |

Decisioni prese dall'orchestratore senza consultare il proprietario, ribaltabili:

- Prefisso del bundle ID `io.github.bateman`; nome dell'app invariato.
- Nessuna migrazione dei dati da un'installazione `dev.ronboger.MishMail`.
- Nessuna modalità diagnostica dettagliata nei log (F-03 ne suggeriva una opzionale).
- Lo script di controllo dei workflow resta come allarme, non come barriera: la protezione vera è l'impostazione del repository "Require actions to be pinned to a full-length commit SHA", che spetta al proprietario attivare.

## Pulizia — Notion Mail

Su richiesta del proprietario, prima dell'ondata 2: rimossa la funzione "Moving from Notion Mail" e ogni riferimento al prodotto in sorgenti, test, script e README (PR #11). L'importazione degli snippet accetta solo il formato di MishMail. Restano intatti le voci passate del changelog e i documenti archiviati dell'upstream.

## Ondata 2 — esito

Chiusa il 24 novembre 2026: quattro PR unite su `main` (#12–#15) con lo stesso flusso dell'ondata 1. In più la PR #10, aperta e unita dal proprietario fuori dal flusso, che si sovrappone allo step 2D e riduce il messaggio d'errore di Gmail.

| Step | Contenuto | PR |
|---|---|---|
| 2A | AI e server MCP spenti dietro un interruttore di build (`MISHMAIL_AI_FEATURES`) | #15 |
| 2B | Cancellazione completa dell'account e notifiche generiche | #14 |
| 2C | Pin di GRDB per commit, riscaricato e verificato a ogni build di CI e di rilascio | #12 |
| 2D | Log residui fuori da `DiagnosticLog` | #13 (e #10) |

| Finding | Stato dopo l'ondata 2 |
|---|---|
| F-01 | Mitigato (ondata 1). Da riprogettare prima di configurare un canale di rilascio. |
| F-02 | Chiuso per la riservatezza. Da provare su Mac con un vero database legacy. |
| F-03 | Chiuso: log diagnostico, log di sistema e rapporto di crash. |
| F-04 | Chiuso. Dopo la PR #18 i dati cancellati vengono sovrascritti nel database e tolti dall'indice di ricerca; i limiti sono in `SECURITY.md`. |
| F-05 | Chiuso. |
| F-06 | Chiuso. |
| F-07 | Chiuso. |
| F-08 | Rimandato alla distribuzione: con l'updater spento non è raggiungibile. |
| F-09 | Chiuso. |
| F-10 | Chiuso per CI e dipendenza. Non verificato: su un Mac, `make release` potrebbe usare la cache globale di SwiftPM senza ricontrollare l'hash. |
| F-11 | Chiuso. |
| F-12 | Chiuso a interruttore spento; ad AI accesa chiuso per il caso segnalato, con i residui corretti nello step 2A. |

Decisioni prese dall'orchestratore senza consultare il proprietario, ribaltabili:

- Rimuovendo un account vengono cancellati anche le viste salvate di quell'account, gli snippet riservati solo a esso, la sua finestra di sincronizzazione e l'intera cache di rete.
- Qualsiasi chiamata a uno strumento lega una chat AI a tutti gli account: rimuovere un account cancella ogni chat che ha usato uno strumento, più tutte quelle precedenti alla migrazione 48. Confermato dal proprietario il 24 novembre 2026.
- Le build di installazione e di rilascio prendono l'interruttore AI solo dalla configurazione tracciata.
- I riassunti e le categorie AI già salvati restano nel database, nascosti.

Scoperto durante l'ondata: `scripts/ci-restore-mtimes.py` ignorava i commit di merge, quindi dopo aver integrato `main` una build con cache poteva collegare un oggetto vecchio. Corretto nella PR #14.

Seguiti annotati, non pianificati:

- Note di licenza di GRDB (MIT) e SQLCipher (BSD a tre clausole) da includere in un binario distribuito; il repository di DuckDuckGo che li confeziona non ha un file di licenza.
- Una sessione di rete effimera per Gmail, al posto della cache condivisa su disco.
- `UITestBreadcrumbs` resta attivabile nelle build di rilascio.
- L'importazione degli snippet legge il file intero senza limite di dimensione.
- Un'azione "dimentica le credenziali AI": chiavi e token dei fornitori restano nel Keychain mentre l'AI è spenta.
- Lo script di riepilogo giornaliero via launchd va disattivato finché l'AI è spenta (documentato in `scripts/README.md`).
- `make release` e il README usano lo xcodegen presente sulla macchina del maintainer.

## Dopo l'ondata 2 — richieste dirette del proprietario

| Contenuto | PR |
|---|---|
| Shortcut predefiniti allineati a Gmail Web, sempre personalizzabili; apertura di una conversazione nel pannello di lettura come predefinito | #17 |
| "Cancellato vuol dire sparito": sovrascrittura nel database e nell'indice di ricerca, pulizia del file di appoggio, rimozione di allegati e notifiche insieme al messaggio, nessuna cache di rete su disco | #18 |

La PR #18 ha avuto due giri di review, il massimo previsto: il secondo ha trovato che il salvataggio di una bozza avrebbe ritirato la notifica di un nuovo messaggio nella stessa conversazione, corretto prima del merge.

Shortcut di Gmail non collegati perché l'app non ha ancora l'azione, candidati per l'ondata 3: silenzia, segna come importante, sposta in, messaggio successivo e precedente dentro una conversazione, espandi e comprimi tutto, `g k`, `g c`, i tasti di formattazione del testo.

Seguiti annotati:

- Conferma prima di un'azione di massa dopo `* a` (Gmail non la chiede; decisione del proprietario).
- `]` e `[` richiedono Opzione su alcune tastiere non americane e lì non sono raggiungibili.
- La sessione di rete del client AI usa ancora la configurazione predefinita, con cookie su disco; l'AI è spenta.
- Il recupero cifrato di un vecchio database in chiaro danneggiato è la parte più voluminosa della PR #18 e serve solo a chi aggiorna da una versione precedente alla cifratura.

## Dopo la prima prova su Mac — secondo giro di richieste del proprietario

| Contenuto | PR |
|---|---|
| Icone di barra laterale, impostazioni e intestazione della lista monocromatiche, come in Gmail | #20 |
| Apertura più rapida della prima conversazione; immagini incorporate tenute in memoria con la conversazione; contenuto cancellato tolto subito dalla memoria; query di "unsubscribe" corretta | #21 |
| Correttore ortografico in più lingue insieme (per esempio inglese e italiano) | #22 |
| Un'email singola si apre espansa da subito nel pannello di lettura | #23 |
| Istruzioni di progetto (`CLAUDE.md`): stile di comunicazione conciso per tutte le sessioni | #24 |
| Colori delle label presi da Gmail, con testo sempre leggibile | #25 |
| Spaziatura compatta tra le sezioni della lista | #26 |

Il proprietario ha unito fuori flusso le nuove icone dell'app in `Design/` e la PR #27 (rigenerazione dei PNG dell'icona).

Esiti da ricordare:

- PR #22: un test su AppKit reale, chiesto in review, ha trovato che dal secondo paragrafo il filtro leggeva la parola sbagliata; corretto prima del merge.
- PR #21: la review ha trovato che un caricamento in corso durante una cancellazione rimetteva in memoria il contenuto cancellato (contro DEC-019); corretto prima del merge. Misure sulla macchina di CI, casella dimostrativa: prima apertura da 736 a 514 ms (mediana). L'obiettivo di 50 ms non è raggiunto in CI e va giudicato sul Mac.
- PR #26: salto tra sezioni da circa 140 pt (riferito dal proprietario) a 29 pt misurati in CI.

Opzione in sospeso, da decidere dopo le prove del proprietario: **cache persistente e cifrata delle immagini**. Renderebbe immediata anche la prima apertura dopo un riavvio; costa byte di immagini su disco, un database più grande e altro contenuto da sovrascrivere alla cancellazione (DEC-019). Non implementare prima della decisione.

Seguiti annotati:

- Selettore della lingua per singolo messaggio nella barra di composizione.
- La pillola delle categorie AI usa ancora lo stile a tinta tenue.
- Pulsante di composizione come pillola colorata, come in Gmail; struttura della barra laterale rispetto a Gmail (Important, Spam, Scheduled, Purchases, More/Less).
- Gli screenshot del README mostrano ancora la barra laterale a colori.
- Scaricare in anticipo le immagini dei messaggi vicini: non fatto, consuma quota Gmail per posta forse mai aperta.
- Con un vecchio build aperto su un database aggiornato, i colori di Gmail verrebbero ricopiati come scelte locali: il ritorno a una versione precedente non è supportato.

## Cancello — prova su Mac del proprietario

☐ Build locale, test e uso della demo.
☐ Verifiche che la CI non copre, emerse dall'ondata 1: pannello Aggiornamenti disabilitato e nessuna richiesta verso GitHub; nuovo accesso a Google con il listener limitato (Safari e Chrome); avvio con un vecchio database in chiaro e una seconda copia aperta (striscia di sola lettura, schermata "Finish encrypting your mail"); eliminazione del vecchio file di log all'avvio.
☐ Verifiche emerse dall'ondata 2 e dalla pulizia: `make install` e il controllo dell'interruttore AI sull'app costruita (comportamento di `plutil` con valore vuoto); nessuna interfaccia AI visibile (impostazioni, palette, barra di composizione, vista del thread); impostazioni, onboarding e palette senza le voci Notion; finestra di conferma della rimozione di un account e rimozione reale (allegati, notifiche); interruttore "Show sender and subject in notifications" e testo delle notifiche; avviso con un errore reale di Gmail.
☐ Verifiche emerse dalle PR #17 e #18: shortcut su tastiera italiana (`]`, `[`, `#`, `*`), cursore nei campi Cc e Bcc e scelta del mittente in composizione, pannello di lettura su finestra stretta e su schermo da 13 pollici, lettura anticipata scorrendo con `j` e `k`; tempo della ricostruzione dell'indice di ricerca al primo avvio; ritiro delle notifiche e rimozione delle copie degli allegati alla cancellazione di un messaggio; nessun `Cache.db` che cresce nella cartella Caches.
☐ Verifiche emerse dalle PR #20–#26: aspetto delle icone monocromatiche e della voce selezionata; email singola espansa (anche in "center peek" e vista compatta, e restringimento per email HTML corte); correttore con English e Italian scelti (menu contestuale, lingua specifica con il sistema su "Automatica per lingua", Cmd-; e pannello Ortografia, reattività con una lunga citazione in una lingua non scelta); riapertura di email con loghi senza sfarfallio, velocità della prima apertura e di `j`/`k`; colori delle label in lista, pannello di lettura e menu, riga selezionata con colore d'accento non blu e a finestra in secondo piano; intestazioni di sezione su macOS 14 e 15, intestazione fissa durante lo scorrimento, vista Labels.
☐ Solo dopo, collegamento di un account Gmail reale.

## Ondata 3 — parità Gmail

- Creazione e modifica dei filtri server-side.
- Gestione dei colori delle label: la visualizzazione con i colori di Gmail è fatta (PR #25); resta la modifica dei colori su Gmail dall'app.
- Verifica ICS/RSVP su inviti reali e gap analysis rispetto a Postie.
- Snooze: richiede prima una scelta di progetto (allineamento con Gmail Web e mobile).

L'ondata 3 parte dopo il cancello: è la prima che aggiunge funzionalità, e ogni step va provato su un account reale.

## Ondata 4 — Calendar e PGP

Entrambi richiedono una decisione di design prima di essere divisi in step: scope e nuovo consenso per Calendar; libreria, chiavi, bozze e ricerca per PGP.

## Stato

| Step | Branch | PR | Stato |
|---|---|---|---|
| 0 | `docs/registro-decisioni-v0.7` | #1 | Unito |
| 1A | `security/fork-identity-updater-off` | #7 | Unito |
| 1B | `security/database-fail-closed` | #2 | Unito |
| 1C | `security/diagnostic-log-privacy` | #4 | Unito |
| 1D | `security/oauth-listener-limits` | #6 | Unito |
| 1E | `ci/least-privilege-pinning` | #5 | Unito |
| 1F | `tests/caret-scroll-deterministic` | #3 | Unito |
| Pulizia | `cleanup/remove-notion-mail` | #11 | Unito |
| 2A | `security/ai-mcp-off-switch` | #15 | Unito |
| 2B | `security/account-removal-notifications` | #14 | Unito |
| 2C | `ci/grdb-revision-pin` | #12 | Unito |
| 2D | `security/residual-logging` | #13 | Unito |
| — | `security/diagnostic-log-privacy` | #10 | Unito dal proprietario, fuori flusso |
| — | `ux/gmail-default-shortcuts` | #17 | Unito |
| — | `security/secure-delete` | #18 | Unito |
| — | `ux/monochrome-sidebar-icons` | #20 | Unito |
| — | `perf/message-open-latency` | #21 | Unito |
| — | `ux/multilingual-spellcheck` | #22 | Unito |
| — | `ux/single-message-reading-pane` | #23 | Unito |
| — | `docs/concise-communication-style` | #24 | Unito |
| — | `ux/readable-label-colors` | #25 | Unito |
| — | `ux/thread-list-section-spacing` | #26 | Unito |
| 3 | — | — | Non avviare: in attesa del proprietario |
