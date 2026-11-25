# Piano di sviluppo a step

Ultimo aggiornamento: 24 novembre 2026
Riferimento: [Registro delle decisioni](registro-decisioni.md) v0.7 (finding F-xx, decisioni DEC-xxx).

Decisioni prese per questo piano:

- Le funzioni AI e il server MCP vengono disattivati per il momento, senza cancellare codice.
- F-01: la segnalazione all'upstream, prima a carico del proprietario, è stata annullata dal proprietario il 25 novembre 2026 (DEC-039).
- L'orchestratore è autorizzato a fare il merge su `main` di `bateman/mishmail` quando CI e review sono a posto.

## Flusso per ogni step

1. Una sessione dedicata (Opus 5.5, impegno medio) implementa lo step su un branch descrittivo, senza "claude" nel nome.
2. La sessione apre subito una PR in bozza verso `bateman/mishmail` (mai verso l'upstream), perché la CI gira solo su PR, push a `main` o avvio manuale.
3. Lo step termina con una nuova suite di test (unità, mock, integrazione) superata in CI. Ogni test di regressione deve fallire sul codice precedente alla correzione.
4. A CI verde la sessione avvisa l'orchestratore, che lancia in parallelo `ponytail-review` in modalità `full` e `security-audit`. Dal 25 novembre 2026 valgono i tre livelli di review di `CLAUDE.md` (DEC-038): questo flusso completo è il livello standard. I due report tornano alla sessione per la risoluzione.
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

Il proprietario ha unito fuori flusso le nuove icone dell'app e le PR #27–#29 (rigenerazione dei PNG dell'icona, svuotamento della cache delle icone di macOS, nuova icona).

Esiti da ricordare:

- PR #22: un test su AppKit reale, chiesto in review, ha trovato che dal secondo paragrafo il filtro leggeva la parola sbagliata; corretto prima del merge.
- PR #21: la review ha trovato che un caricamento in corso durante una cancellazione rimetteva in memoria il contenuto cancellato (contro DEC-019); corretto prima del merge. Misure sulla macchina di CI, casella dimostrativa: prima apertura da 736 a 514 ms (mediana). L'obiettivo di 50 ms non è raggiunto in CI e va giudicato sul Mac.
- PR #26: salto tra sezioni da circa 140 pt (riferito dal proprietario) a 29 pt misurati in CI.

Opzione rimasta in sospeso in questo giro e decisa nel quarto: **cache persistente e cifrata delle immagini** (DEC-032, PR #39).

Seguiti annotati:

- Selettore della lingua per singolo messaggio nella barra di composizione.
- La pillola delle categorie AI usa ancora lo stile a tinta tenue.
- Pulsante di composizione come pillola colorata, come in Gmail; struttura della barra laterale rispetto a Gmail (Important, Spam, Scheduled, Purchases, More/Less).
- Gli screenshot del README mostrano ancora la barra laterale a colori.
- Scaricare in anticipo le immagini dei messaggi vicini: non fatto, consuma quota Gmail per posta forse mai aperta.
- Con un vecchio build aperto su un database aggiornato, i colori di Gmail verrebbero ricopiati come scelte locali: il ritorno a una versione precedente non è supportato.

## Terzo giro di richieste del proprietario

| Contenuto | PR |
|---|---|
| Colore della label dell'account, scelto in "Edit Account Labels…" con il selettore di colore di sistema; pillola con la stessa regola di leggibilità delle label Gmail | #31 |
| Foto profilo Google come avatar dell'account | #32 |
| CI: test Python degli script, warning di compilazione come errori, `shellcheck`; nuovi target `make checks`, `make script-tests`, `make shellcheck` | #33 |
| Icone della barra laterale meno arrotondate (dimensione del titolo, tratto medio) e icona della voce selezionata non più nel colore d'accento | #34 |

Esiti da ricordare:

- PR #32: nessun nuovo permesso Google (`userinfo.profile` era già richiesto). La foto si scarica solo da `lh3`–`lh6.googleusercontent.com`, senza token né cookie, al massimo una volta al giorno; sta nel database cifrato e viene cancellata con l'account. È la prima nuova destinazione di rete aggiunta dal fork.
- PR #31 e #32 aggiungono le migrazioni v52 e v53, in quest'ordine.
- PR #33: `make release` aspetta una CI completa, che ora fallisce su qualsiasi warning; i binari di rilascio sono compilati senza il blocco. Un nuovo warning dopo un aggiornamento di Xcode sulla macchina di CI blocca un rilascio finché non è corretto.
- PR #34: la causa dell'aspetto arrotondato era dimensione e peso scelti dalla barra laterale di sistema, non un font arrotondato. Con il focus sulla barra laterale la selezione resta la capsula nel colore d'accento con icona bianca, come nelle app macOS; senza focus è grigia con icona scura. In attesa di conferma del proprietario.
- Il job dei test di interfaccia dura ora circa undici minuti.

Rimandati dal proprietario (osservazioni sull'infrastruttura di CI): Dependabot per pacchetti Swift e script Python, lint Swift e CodeQL, misura della copertura, hook git versionati. Non verificato: se la protezione del ramo `main` richiede i controlli di CI.

Seguiti annotati:

- Un account senza foto mostra l'immagine con la lettera generata da Google, non distinguibile da una foto vera.
- Avatar anche nel selettore del mittente in composizione, se desiderato.
- Su macOS precedenti al 26 il colore predefinito della pillola dell'account può differire leggermente da quello del disco dell'avatar.
- La build dei test di interfaccia non passa il blocco sui warning.

## Quarto giro di richieste del proprietario

| Contenuto | PR |
|---|---|
| Colore dell'account come anello intorno alla foto; nome della label come titolo dell'account al posto del nome del mittente; pillola dell'account rimossa | #36 |
| Label a forma di rettangolo arrotondato come in Gmail, senza contorno sulle righe normali | #37 |
| Pannello di lettura: i messaggi di una conversazione sono righe piatte separate da un filetto, come in Gmail | #38 |
| Cache persistente e cifrata delle immagini incorporate (migrazione v54) | #39 |
| Immagini remote caricate per impostazione predefinita all'apertura; Spam sempre bloccato; nessun caricamento anticipato | #40 |
| Anello dell'account a spessore doppio (3 pt). Modifica semplice: sessione Sonnet, nessuna review, unita a CI verde (DEC-036) | #41 |
| Cache cifrata delle immagini remote, solo dove sono già permesse (migrazione v55) | #42, in lavorazione |
| Colore d'accento configurabile in Settings → Appearance | #43 |
| Badge delle non lette sull'icona nel Dock: aggiornamento immediato dopo le azioni locali, ridisegno al ritorno nell'app, riga "Shown by macOS" nelle impostazioni | #45 |

Il 24 novembre 2026 il proprietario ha sostituito l'orchestratore con una nuova sessione (DEC-037). Le sessioni non toccano più `CHANGELOG.md` né `docs/`: propongono le righe nel corpo della PR e l'orchestratore le raccoglie in una PR di documentazione.

Esiti da ricordare:

- PR #36: l'anello predefinito usa lo stesso colore di sistema del disco con l'iniziale; sotto 1,5:1 di contrasto con lo sfondo si aggiunge un filetto neutro, il colore scelto non viene mai alterato. Una label riempita in automatico con il nome del profilo Google resta visibile dopo una modifica di "Send as": si corregge modificando la label.
- PR #37: il contorno si decide con una distanza di colore (CIE76), non con il rapporto WCAG, perché i pastelli di Gmail sono chiari quanto la riga letta. Le label restano a destra, prima della data.
- PR #38: riga compressa di 80 pt senza spazio tra le righe (prima scheda di circa 72 pt più 12 pt). L'avatar della propria posta vale solo per i messaggi che Gmail ha archiviato come SENT da un proprio indirizzo o alias: un mittente falsificato non riceve la foto. Nessun anello dell'account nelle righe dei messaggi.
- PR #39: immagini solo dentro il database cifrato, mai in file; 200 MiB in tutto, 3 MiB per messaggio, esce prima ciò che è usato meno di recente; cancellazione a cascata con allegato, messaggio e account. Nessun confronto di latenza in CI: da giudicare sul Mac.
- PR #40: un'installazione che non aveva mai scelto segue il nuovo predefinito; una scelta salvata resta; un valore sconosciuto vale "Ask". Con un tasto freccia tenuto premuto si apre solo la conversazione su cui ci si ferma. Nessun avviso nell'app per chi non aveva mai scelto: lo dice solo il changelog. `SECURITY.md` ha una nuova nota "Remote images".

- PR #43: Settings → Appearance → "Accent color" (selettore di sistema, colori rapidi, "Default" = aspetto di prima). Il testo sopra l'accento diventa bianco o nero; l'accento usato come testo o icona viene corretto in luminosità quanto basta; i pulsanti di sistema usano una variante scurita. L'evidenziazione della riga selezionata nel colore scelto vale solo su macOS 26 e successivi: su macOS 14 e 15 resta quella di sistema. Restano al sistema la selezione del testo, i controlli nativi e gli avvisi. Ha toccato 45 file dell'interfaccia.
- PR #45: il badge esisteva già e usava il supporto di sistema (`dockTile.badgeLabel`); il proprietario ha segnalato che sul suo Mac non compare affatto. Nel codice non è stata trovata una causa certa: la PR toglie i casi in cui un disegno perso non veniva ritentato e mostra nelle impostazioni lo stato riferito da macOS. La causa sul Mac del proprietario resta da accertare. Le skill `ponytail-review` e `security-audit` non erano disponibili nella sessione dell'orchestratore: le due review sono state fatte a mano da agenti.

Seguiti annotati:

- Label prima dell'oggetto come in Gmail (oggi a destra, prima della data): offerto come lavoro separato.
- Le label senza colore sono grigio neutro come in Gmail; il proprietario può chiedere di tornare al colore automatico per nome.
- Avviso nell'app per chi non aveva mai impostato "Load remote images".
- Comando "Svuota cache immagini" nelle impostazioni (oggi non esiste una sezione su archiviazione o privacy).
- Sospetto preesistente, da verificare su Mac: `preconnect` e `dns-prefetch` nell'HTML di un messaggio potrebbero risolvere o contattare host del mittente anche a immagini bloccate. La ricetta di prova è nel corpo della PR #40.
- La preparazione anticipata del documento resta attiva per la variante bloccata: da misurare.
- Il messaggio più lungo del benchmark ha ora 43 messaggi invece di 40: i numeri non sono confrontabili uno a uno con quelli precedenti.

## Cancello — prova su Mac del proprietario

☐ Build locale, test e uso della demo.
☐ Verifiche che la CI non copre, emerse dall'ondata 1: pannello Aggiornamenti disabilitato e nessuna richiesta verso GitHub; nuovo accesso a Google con il listener limitato (Safari e Chrome); avvio con un vecchio database in chiaro e una seconda copia aperta (striscia di sola lettura, schermata "Finish encrypting your mail"); eliminazione del vecchio file di log all'avvio.
☐ Verifiche emerse dall'ondata 2 e dalla pulizia: `make install` e il controllo dell'interruttore AI sull'app costruita (comportamento di `plutil` con valore vuoto); nessuna interfaccia AI visibile (impostazioni, palette, barra di composizione, vista del thread); impostazioni, onboarding e palette senza le voci Notion; finestra di conferma della rimozione di un account e rimozione reale (allegati, notifiche); interruttore "Show sender and subject in notifications" e testo delle notifiche; avviso con un errore reale di Gmail.
☐ Verifiche emerse dalle PR #17 e #18: shortcut su tastiera italiana (`]`, `[`, `#`, `*`), cursore nei campi Cc e Bcc e scelta del mittente in composizione, pannello di lettura su finestra stretta e su schermo da 13 pollici, lettura anticipata scorrendo con `j` e `k`; tempo della ricostruzione dell'indice di ricerca al primo avvio; ritiro delle notifiche e rimozione delle copie degli allegati alla cancellazione di un messaggio; nessun `Cache.db` che cresce nella cartella Caches.
☐ Verifiche emerse dalle PR #20–#26: aspetto delle icone monocromatiche e della voce selezionata; email singola espansa (anche in "center peek" e vista compatta, e restringimento per email HTML corte); correttore con English e Italian scelti (menu contestuale, lingua specifica con il sistema su "Automatica per lingua", Cmd-; e pannello Ortografia, reattività con una lunga citazione in una lingua non scelta); riapertura di email con loghi senza sfarfallio, velocità della prima apertura e di `j`/`k`; colori delle label in lista, pannello di lettura e menu, riga selezionata con colore d'accento non blu e a finestra in secondo piano; intestazioni di sezione su macOS 14 e 15, intestazione fissa durante lo scorrimento, vista Labels.
☐ Verifiche emerse dalle PR #31–#34: editor del colore della label (pannello colori di sistema, chiusura all'uscita, riga disattivata quando la pillola non si vede), testo nero sulle pillole predefinite blu, viola e rosa; foto profilo con un account reale (download, aspetto, account senza foto, uscita dall'app subito dopo una sincronizzazione, VoiceOver nel menu degli account); icone in modalità scura, con accento giallo o grafite, con dimensione della barra laterale piccola e grande, su macOS 14 e 15.
☐ Verifiche emerse dalle PR #36–#41: aspetto dell'anello sulle superfici reali (barra laterale, popover, impostazioni), centratura del testo dell'intestazione e altezza delle righe del popover, lettura di VoiceOver; forma delle label (testo centrato, troncamento al limite); righe dei messaggi in modalità scura con posta HTML, pannelli stretti con testo grande, pannello di 400–450 pt con un mittente dal nome lungo; immagini incorporate dopo un riavvio con posta reale e velocità percepita; piè di pagina delle impostazioni sulle immagini remote, messaggio in Spam con "Load images", comportamento reale di rete all'apertura, tasto freccia tenuto premuto; prova di `preconnect` e `dns-prefetch` a immagini bloccate.
☐ Verifiche emerse dalla PR #43: accento personalizzato in modalità scura, pannello colori reale (anche colori P3), barra laterale delle impostazioni e contatori sulla riga selezionata, eventuali lampi di un fotogramma dell'evidenziazione di sistema mentre la selezione si sposta, raggio della capsula, comportamento su macOS 14 e 15.
☐ Verifiche emerse dalla PR #45: il badge compare sull'icona nel Dock; in caso contrario, riga "Shown by macOS" in Settings ▸ Dock badge, `lsappinfo info -only StatusLabel "MishMail"` e interruttore "Badge sull'icona dell'app" in Impostazioni di Sistema ▸ Notifiche; il pulsante apre il pannello Notifiche; il numero cambia subito dopo lettura, archiviazione e cancellazione.
☐ Solo dopo, collegamento di un account Gmail reale.

## Ondata 3 — parità Gmail

- Creazione e modifica dei filtri server-side.
- Gestione dei colori delle label: la visualizzazione con i colori di Gmail è fatta (PR #25); resta la modifica dei colori su Gmail dall'app.
- Verifica ICS/RSVP su inviti reali e gap analysis rispetto a Postie.
- Snooze: richiede prima una scelta di progetto (allineamento con Gmail Web e mobile).

Avviata dal proprietario il 25 novembre 2026, prima che il cancello fosse completato: ogni step va comunque provato su un account reale, e i passi di prova stanno nel corpo di ciascuna PR.

| Step | Contenuto | Branch | Migrazione riservata |
|---|---|---|---|
| 3A | Creazione e modifica dei filtri lato server | `feature/gmail-server-filters` | v56 |
| 3B | Modifica dei colori delle label su Gmail | `feature/gmail-label-color-editing` | v57 |
| 3C | Verifica ICS/RSVP e analisi delle lacune | `feature/ics-rsvp-verification` | v59 |
| 3D | Snooze: prima l'analisi e le opzioni, poi la scelta del proprietario | `feature/snooze-gmail-alignment` | v60 |
| 3E | Azioni mancanti degli shortcut di Gmail | `feature/gmail-shortcut-actions` | v58 |

## Ondata 4 — Calendar e PGP

Entrambi richiedono una decisione di design prima di essere divisi in step: scope e nuovo consenso per Calendar; libreria, chiavi, bozze e ricerca per PGP.

## Lavori in sospeso

Aggiornato il 25 novembre 2026.

### Seguiti offerti, nessuno deciso

- Label prima dell'oggetto come in Gmail.
- Comando "Svuota cache immagini" nelle impostazioni.
- Avviso nell'app per chi non aveva mai impostato "Load remote images".
- Immagini remote con una sola richiesta al mittente (2–3 giorni).
- Conferma prima di un'azione di massa dopo `* a`.
- Struttura della barra laterale come Gmail.
- Selettore della lingua per messaggio.
- Avatar nel selettore del mittente.

### Rimandato dal proprietario

- Dependabot per Swift e Python, SwiftLint e CodeQL, misura della copertura, hook git versionati.

### Prima di distribuire l'app ad altri

- Riprogettare la regola di fiducia dell'updater, note di licenza di GRDB e SQLCipher, firma e notarizzazione.

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
| — | `docs/ux-round-2` | #30 | Unito |
| — | `feature/account-label-color` | #31 | Unito |
| — | `feature/account-profile-photo` | #32 | Unito |
| — | `ci/script-tests-warnings-shellcheck` | #33 | Unito |
| — | `ux/sidebar-icon-shape` | #34 | Unito |
| — | `docs/ux-round-3` | #35 | Unito |
| — | `ux/account-ring-and-label-title` | #36 | Unito |
| — | `ux/gmail-label-shape` | #37 | Unito |
| — | `ux/thread-message-list-spacing` | #38 | Unito |
| — | `perf/persistent-image-cache` | #39 | Unito |
| — | `ux/remote-images-default-on` | #40 | Unito |
| — | `ux/account-ring-thicker` | #41 | Unito, modifica semplice senza review |
| — | `perf/remote-image-cache` | #42 | In lavorazione |
| — | `ux/custom-accent-color` | #43 | Unito |
| — | `docs/ux-round-4` | #44 | Documentazione del quarto giro |
| — | `feature/unread-dock-badge` | #45 | Unito |
| — | `docs/process-review-tiers` | #46 | Unito, modifica semplice |
| 3A–3E | vedi "Ondata 3" | — | In lavorazione dal 25 novembre 2026 |
