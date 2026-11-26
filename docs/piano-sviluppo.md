# Piano di sviluppo a step

Ultimo aggiornamento: 25 novembre 2026
Riferimento: [Registro delle decisioni](registro-decisioni.md) v0.7 (finding F-xx, decisioni DEC-xxx).

Decisioni prese per questo piano:

- Le funzioni AI e il server MCP vengono disattivati per il momento, senza cancellare codice.
- F-01: la segnalazione all'upstream, prima a carico del proprietario, è stata annullata dal proprietario il 25 novembre 2026 (DEC-039).
- L'orchestratore è autorizzato a fare il merge su `main` di `bateman/dreamail` (prima `bateman/mishmail`) quando CI e review sono a posto.

## Flusso per ogni step

1. Una sessione dedicata (Opus 5.5, impegno medio) implementa lo step su un branch descrittivo, senza "claude" nel nome.
2. La sessione apre subito una PR in bozza verso `bateman/dreamail` (prima `bateman/mishmail`) (mai verso l'upstream), perché la CI gira solo su PR, push a `main` o avvio manuale.
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
| Cache cifrata delle immagini remote, solo dove sono già permesse (migrazione v55). Prima apertura come prima, con salvataggio in secondo piano (DEC-043) | #42 |
| Colore d'accento configurabile in Settings → Appearance | #43 |
| Badge delle non lette sull'icona nel Dock: aggiornamento immediato dopo le azioni locali, ridisegno al ritorno nell'app, riga "Shown by macOS" nelle impostazioni | #45 |

Il 24 novembre 2026 il proprietario ha sostituito l'orchestratore con una nuova sessione (DEC-037). Le sessioni non toccano più `CHANGELOG.md` né `docs/`: propongono le righe nel corpo della PR e l'orchestratore le raccoglie in una PR di documentazione.

Esiti da ricordare:

- PR #36: l'anello predefinito usa lo stesso colore di sistema del disco con l'iniziale; sotto 1,5:1 di contrasto con lo sfondo si aggiunge un filetto neutro, il colore scelto non viene mai alterato. Una label riempita in automatico con il nome del profilo Google resta visibile dopo una modifica di "Send as": si corregge modificando la label.
- PR #37: il contorno si decide con una distanza di colore (CIE76), non con il rapporto WCAG, perché i pastelli di Gmail sono chiari quanto la riga letta. Le label restano a destra, prima della data.
- PR #38: riga compressa di 80 pt senza spazio tra le righe (prima scheda di circa 72 pt più 12 pt). L'avatar della propria posta vale solo per i messaggi che Gmail ha archiviato come SENT da un proprio indirizzo o alias: un mittente falsificato non riceve la foto. Nessun anello dell'account nelle righe dei messaggi.
- PR #39: immagini solo dentro il database cifrato, mai in file; 200 MiB in tutto, 3 MiB per messaggio, esce prima ciò che è usato meno di recente; cancellazione a cascata con allegato, messaggio e account. Nessun confronto di latenza in CI: da giudicare sul Mac.
- PR #40: un'installazione che non aveva mai scelto segue il nuovo predefinito; una scelta salvata resta; un valore sconosciuto vale "Ask". Con un tasto freccia tenuto premuto si apre solo la conversazione su cui ci si ferma. Nessun avviso nell'app per chi non aveva mai scelto: lo dice solo il changelog. `SECURITY.md` ha una nuova nota "Remote images".

- PR #42: alla prima apertura le immagini sono chieste due volte al mittente (dal visualizzatore e dall'app, che non può leggere i byte scaricati dal visualizzatore). Un messaggio si riapre dalla cache solo quando tutte le sue immagini sono "sistemate": salvate, oppure rifiutate e ricordate come tali (pixel, SVG, troppo grandi, oltre il tetto). Gli errori di rete non vengono ricordati e si ritentano. La review sul percorso nuovo ha trovato un difetto serio (immagini incorporate mai mostrate a freddo con cache completa) corretto prima dell'unione.
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

Controlli che la CI non può fare. Il proprietario usa l'app come client quotidiano e li segna come risolti man mano, citando il numero (per esempio "C-12 risolto"). Il cancello non blocca più l'ondata 3 (DEC-040). I controlli delle PR dell'ondata 3 si aggiungono qui quando vengono unite.

Aggiornato il 25 novembre 2026.

### Avvio, build, aggiornamenti

- ☑ **C-01** Build locale e avvio (`make run` o `make install`).
- ☑ **C-02** Account Gmail reale collegato e in uso.
- ☐ **C-03** Pannello Aggiornamenti disabilitato e nessuna richiesta verso GitHub.
- ☐ **C-04** `make install`: controllo dell'interruttore AI sull'app costruita (comportamento di `plutil` con valore vuoto).
- ☐ **C-05** Nessuna interfaccia AI visibile: impostazioni, palette, barra di composizione, vista del thread.
- ☐ **C-06** Impostazioni, onboarding e palette senza le voci Notion.
- ☐ **C-07** Eliminazione del vecchio file di log all'avvio.

### Accesso e account

- ☐ **C-08** Nuovo accesso a Google con il listener limitato, da Safari e da Chrome.
- ☐ **C-09** Avvio con un vecchio database in chiaro e una seconda copia aperta: striscia di sola lettura, schermata "Finish encrypting your mail".
- ☐ **C-10** Finestra di conferma della rimozione di un account e rimozione reale (allegati, notifiche).
- ☐ **C-11** Foto profilo con un account reale: download, aspetto, account senza foto, uscita dall'app subito dopo una sincronizzazione.
- ☐ **C-12** Avviso con un errore reale di Gmail.

### Notifiche e badge

- ☑ **C-13** Il badge delle non lette compare sull'icona nel Dock. Causa del badge assente: notifiche disattivate per l'app in macOS; la riga "Shown by macOS" lo segnala (25 novembre 2026).
- ☐ **C-14** Il numero del badge cambia subito dopo lettura, archiviazione e cancellazione.
- ☐ **C-15** Il pulsante "Open Notification Settings…" apre il pannello Notifiche.
- ☐ **C-16** Interruttore "Show sender and subject in notifications" e testo delle notifiche.
- ☐ **C-17** Ritiro delle notifiche e rimozione delle copie degli allegati alla cancellazione di un messaggio.

### Tastiera e composizione

- ☐ **C-18** Shortcut su tastiera italiana: `]`, `[`, `#`, `*`.
- ☐ **C-19** Cursore nei campi Cc e Bcc e scelta del mittente in composizione.
- ☐ **C-20** Lettura anticipata scorrendo con `j` e `k`; tasto freccia tenuto premuto apre solo la conversazione su cui ci si ferma.
- ☐ **C-21** Correttore con English e Italian scelti: menu contestuale, lingua specifica con il sistema su "Automatica per lingua", Cmd-; e pannello Ortografia, reattività con una lunga citazione in una lingua non scelta.

### Lista e barra laterale

- ☐ **C-22** Icone monocromatiche e voce selezionata; modalità scura; dimensione della barra laterale piccola e grande.
- ☐ **C-23** Colori e forma delle label in lista, pannello di lettura e menu: testo centrato, troncamento al limite.
- ☐ **C-24** Intestazioni di sezione, intestazione fissa durante lo scorrimento, vista Labels.
- ☐ **C-25** Anello dell'account su barra laterale, popover e impostazioni; centratura del testo dell'intestazione; altezza delle righe del popover.
- ☐ **C-26** Editor del colore della label dell'account: pannello colori di sistema, chiusura all'uscita.
- ☐ **C-27** Colore d'accento personalizzato: modalità scura, pannello colori reale (anche colori P3), barra laterale delle impostazioni, contatori sulla riga selezionata, lampi dell'evidenziazione di sistema mentre la selezione si sposta, raggio della capsula.

### Pannello di lettura e immagini

- ☐ **C-28** Pannello di lettura su finestra stretta e su schermo da 13 pollici.
- ☐ **C-29** Email singola espansa, anche in "center peek" e vista compatta; restringimento per email HTML corte.
- ☐ **C-30** Righe dei messaggi di una conversazione: modalità scura con posta HTML, pannelli stretti con testo grande, pannello di 400–450 pt con un mittente dal nome lungo.
- ☐ **C-31** Riapertura di email con loghi senza sfarfallio; velocità della prima apertura e di `j`/`k`.
- ☐ **C-32** Immagini incorporate dopo un riavvio con posta reale.
- ☐ **C-33** Immagini remote: piè di pagina delle impostazioni, messaggio in Spam con "Load images", comportamento reale di rete all'apertura.
- ☐ **C-34** Prova di `preconnect` e `dns-prefetch` a immagini bloccate (ricetta nel corpo della PR #40).

### Dati e cancellazione

- ☐ **C-35** Tempo della ricostruzione dell'indice di ricerca al primo avvio.
- ☐ **C-36** Nessun `Cache.db` che cresce nella cartella Caches.

### Accessibilità e altre versioni di macOS

- ☐ **C-37** VoiceOver: menu degli account, righe dei messaggi, anello dell'account.
- ☐ **C-38** macOS 14 e 15: intestazioni di sezione, icone, selezione con accento personalizzato (lì resta quella di sistema).

### Aggiunti dalle PR unite dopo il 25 novembre 2026

- ☐ **C-39** Cache delle immagini remote (PR #42): una newsletter riaperta, anche dopo un riavvio, mostra le immagini senza rete; sensazione della breve attesa prima del primo disegno (al massimo 150 ms); messaggi con immagini incorporate e remote insieme. **Provato dal proprietario il 25 novembre 2026: non superato** (più lento di prima, corpo tagliato, 20–30 s su alcune mail alla prima apertura); correzione nella PR #59. Dopo la correzione (PR #59) il proprietario ha confermato che il corpo compare a tutta altezza; il logo mancante della ricevuta SumUp non è un difetto (non si vede nemmeno su Gmail web: il server non lo serve più). Resta da confermare che la velocità di apertura sia tornata normale.
- ☐ **C-40** Inviti di calendario (PR #51): invito da Google Calendar, da Outlook/Exchange e da Apple Calendar; Accetta, Forse, Rifiuta cambiano lo stato presso l'organizzatore; riga "Reply from … goes to …"; avviso arancione se l'organizzatore non è il mittente; evento spostato chiede di nuovo; occorrenza o serie annullata senza pulsanti; risposta da un alias. Passi completi nel corpo della PR #51.
- ☐ **C-41** Colore delle label su Gmail (PR #48): DreaMail → Organize Labels → clic sul pallino di una label utente → "Color on Gmail"; il colore compare subito e, entro un minuto, su Gmail web e telefono; dopo una sync non torna indietro; "No color on Gmail" toglie davvero il colore (non verificato: la documentazione non lo dice); senza rete torna il colore vecchio con un avviso; il colore solo-Mac resta prevalente. Passi completi nel corpo della PR #48.
- ☐ **C-42** Shortcut di Gmail (PR #50): `m` silenzia davvero su un account reale e `m` di nuovo toglie il silenzio (non verificato: l'API di Gmail potrebbe rifiutare la label `MUTED`; in quel caso la conversazione torna con un avviso); `+` / `-` importanza; `v` sposta, anche da una vista label, dal Cestino, con righe spuntate di due account e dalla barra della conversazione con altre righe spuntate; `n` / `p` / `;` / `:` in una conversazione; tutti i tasti su tastiera italiana. Passi completi nel corpo della PR #50.
- ☐ **C-43** Filtri Gmail (PR #49): DreaMail → ⌘, → Gmail filters; creare un filtro, modificarlo, cancellarlo e ritrovare lo stesso risultato su Gmail web; anteprima dei messaggi corrispondenti; conferma prima di salvare un filtro che cancella o salta la Inbox; messaggio di Gmail per un filtro già esistente; un filtro con inoltro non è modificabile ma si può cancellare; soglia di dimensione in MB. Passi completi nel corpo della PR #49.
- ☐ **C-44** Snooze allineato a Gmail (PR #47): posticipare una conversazione su Gmail web, poi Sync in DreaMail: compare sotto Snoozed con "Snoozed in Gmail" e non è in Inbox (non verificato da nessuno: che l'API di Gmail accetti `in:snoozed` e restituisca solo la posta posticipata); "Unsnooze" su Gmail web la riporta in Inbox dopo la sync; posticipare in DreaMail su un account di prova e rimuovere l'account: su Gmail web la conversazione è di nuovo in Inbox; senza rete la rimozione si completa e un avviso dice quante sono rimaste archiviate. Passi completi nel corpo della PR #47.
- ☐ **C-45** Google Calendar (PR #55 e #57, solo con `DREAMAIL_CALENDAR = YES` in `Local.xcconfig`, da provare quando l'interfaccia è unita): consenso reale; risposta a un invito di un organizzatore Google (deve ricevere una sola notifica: non verificato); risposta a un invito Outlook; "Add to Google Calendar" su un evento già presente (non verificato cosa fa Google con un identificativo esistente); rimozione dell'account: permesso e calendari scelti spariscono.
- ☐ **C-46** Azioni al passaggio del mouse (PR #52): con il mouse su una riga della lista compaiono, da sinistra, archivia, cestina, segna come non letta/letta, posticipa; ciascuna agisce su quella riga senza aprire la conversazione; la stella è a sinistra del mittente; la data non è tagliata con testo grande; la riga non salta entrando e uscendo con il mouse; resa con il pannello di lettura aperto (lista stretta).
- ☐ **C-47** Badge dei non letti per account (PR #58): nel selettore degli account ogni foto profilo ha il suo numero in alto a destra, sopra l'anello; sparisce a zero; "99+" oltre 99; nessun badge su "tutti gli account"; la somma coincide con il Dock se il badge del Dock conta tutti gli account; alone e contrasto in modalità chiara e scura.
- ☐ **C-48** Impostazioni per account (PR #60): DreaMail → ⌘, → Accounts: ogni account ha il proprio interruttore "Show sender and subject in notifications" (gli account esistenti mantengono la scelta di prima); con l'interruttore acceso su un account e spento su un altro, le notifiche del secondo restano generiche; spegnendolo, le notifiche già consegnate di quell'account spariscono dal Centro notifiche (non verificato contro un vero Centro notifiche); "Show Filters…" apre i filtri di quell'account.
- ☐ **C-49** Intestazioni della lista più scure (PR #64) e `make run` con l'account reale (PR #66): "Today", "Yesterday" e le altre sono più scure di mittente e oggetto dei messaggi letti, in modalità chiara e scura; `make run` apre l'account reale, `make run DEMO=1` la casella finta.
- ☐ **C-50** Firme per account (PR #61): DreaMail → Settings (⌘,) → Signatures. Creare due firme, impostare la predefinita per i nuovi messaggi e per le risposte di ogni indirizzo; "Import from Gmail" porta le firme di Gmail (una firma con tabella resta leggibile, le immagini sono tolte e la cosa è detta). In composizione: la firma predefinita compare da sola; cambiando From la firma cambia; il menu "Insert signature / No signature / Manage signatures" la sostituisce o la toglie; un P.S. scritto sotto la firma non viene cancellato; ⌘Z annulla il cambio.
- ☐ **C-51** Immagini fallite nascoste (PR #67): aprire la ricevuta SumUp: al posto del "?" blu non compare nulla. Da guardare: un'immagine fallita con testo alternativo e dimensioni fisse potrebbe mostrare ancora il "?" (non verificato).
- ☐ **C-52** Barra degli account (PR #62): striscia sempre visibile a sinistra della barra laterale. Un avatar per account con il suo numero di non letti; clic cambia account; "All accounts" in cima con più account; "+" aggiunge un account; ingranaggio in basso apre Settings. ⌘1…⌘9 come prima; trascinare un avatar riordina gli account; colori in modalità chiara e scura; gli avvisi in basso (annulla) non coprono l'ingranaggio; con un solo account l'avatar appare selezionato.
- ☐ **C-53** Dimensione della finestra all'avvio (PR #65): ridimensionare e spostare la finestra principale, uscire con ⌘Q, riaprire: la finestra torna con la stessa dimensione e posizione. La prima volta dopo l'aggiornamento parte con la dimensione predefinita (il nome di salvataggio è cambiato). Provare anche con `make run` dopo una ricompilazione.
- ☐ **C-54** Barra laterale come Gmail (PR #63): (1) viste di sistema nell'ordine di Gmail: Inbox, Starred, Snoozed, Important, Sent, Drafts, All Mail, Trash, poi "More"; (2) "More" apre Spam, Categories e, se presenti, Scheduled; resta com'era dopo ⌘Q; (3) sotto "Labels" le etichette ad albero come in Gmail, con colore e non letti; un genitore aperto resta aperto dopo il riavvio; (4) un'etichetta nascosta in Gmail sta sotto il "More" delle etichette; (5) "+" accanto a Labels: creare `test`, poi `test2` annidata sotto `test`; entrambe compaiono in Gmail web; (6) con tutti gli account: un albero per account; aprire un'etichetta dell'account A e passare a B dalla barra porta alla Inbox di B; (7) `g l` e Go ▸ Labels aprono ancora la vista di tutte le etichette; (8) Spam mostra solo lo spam arrivato da quando l'account è stato aggiunto. Non verificato senza Mac: etichette reali con "mostra se non lette"/"nascondi", resa in modalità scura, creazione reale su Gmail.
- ☐ **C-55** OpenPGP (PR #68), solo con l'interruttore acceso (`DREAMAIL_PGP = YES` in `Config/Signing.xcconfig`): (1) con l'interruttore spento non compare nulla di PGP, né in Settings né nei messaggi; (2) DreaMail → Settings (⌘,) → OpenPGP keys: importare una chiave pubblica da file: prima di salvare compare una finestra con impronta, tutti gli indirizzi dichiarati e validità; (3) un messaggio firmato dal mittente di quella chiave mostra l'indicatore accanto al mittente, con i dettagli al clic; un messaggio firmato da una chiave sconosciuta dice che non si può verificare; (4) importare la propria chiave privata, aprire un messaggio cifrato: chiede la passphrase e mostra il testo; dopo il blocco dello schermo la richiede di nuovo; (5) eliminare una chiave: sparisce da Settings e dal Portachiavi; (6) rimuovere un account: spariscono le sue chiavi. I messaggi di GnuPG 2.4 si decifrano (libreria v0.1.1, PR #72). Limiti noti: una chiave scaduta va eliminata prima di importare quella rinnovata; gli allegati dentro un messaggio cifrato non sono ancora elencati.
- ☐ **C-56** Rinomina in DreaMail (DEC-065): aggiornare `Config/Local.xcconfig` ai nomi `DREAMAIL_…`; `make clean`, `make install`: si installa `/Applications/DreaMail.app` e i controlli di `make install` passano; al primo avvio nessuna richiesta inattesa del Portachiavi; incollare client ID e secret, accedere agli account, sincronizzare, inviare un messaggio; nome "DreaMail" in Dock, barra dei menu, About (con la riga "Based on MishMail by Ron Boger" e senza "Support") e Impostazioni; reimpostare client e-mail predefinito, notifiche e firme; un link `dreamail://` apre la conversazione; i test UI (`make ui-test-ci`) passano; rimuovere un account e una chiave OpenPGP: spariscono come prima (DEC-019). Dopo qualche giorno, pulizia della vecchia installazione con i comandi del README ("Coming from a MishMail install of this fork"). Rifare le schermate in `docs/screenshots/`.
- ☐ **C-57** Categorie chiuse (PR #76): aprire Categories, selezionare Promotions, chiudere Categories: Promotions sparisce dalla barra e la lista resta su Promotions; lo stesso con un'etichetta figlia e il genitore chiuso; con "Less" la vista aperta resta visibile.
- ☐ **C-58** Immagini delle newsletter (PR #75): aprire il messaggio Springer Nature e altre newsletter con immagini consentite: le immagini compaiono come in Gmail; un'immagine che non si carica mostra il testo alternativo in piccolo, se c'è. Se mancano ancora, mandare le righe `<img` da "Show original".
- ☐ **C-59** Barra degli account, rifiniture (PR #77): i pulsanti chiudi, riduci e ingrandisci stanno per intero sulla barra (90 pt), anche a schermo intero e uscendone; "All accounts" ha un sottile anello grigio quando non è selezionato, visibile in chiaro e in scuro; Settings → Appearance → "Show Add Account button in the account rail" nasconde e mostra il "+"; sotto 1170 pt la finestra passa al layout compatto.
- ☐ **C-60** Selettore etichette (PR #74): con una conversazione selezionata aprire il selettore (`l`): Invio applica l'etichetta evidenziata e chiude; Spazio spunta o toglie senza chiudere, come il clic; più selezioni col mouse e poi Esc per uscire; "Create new" apre la finestra di creazione e, mentre è aperta, i tasti vanno al suo campo di testo.
- ☐ **C-61** Firme come Gmail (PR #79; sostituisce in C-50 il passo "Import from Gmail"): (1) all'avvio le firme di Gmail di ogni indirizzo compaiono da sole in Settings → Signatures, senza importarle; (2) una firma nuova di Gmail diventa predefinita solo per i nuovi messaggi e solo se non ce n'era una; la predefinita per le risposte resta quella scelta a mano; (3) in composizione il menu a penna, come in Gmail, elenca "No signature" e le firme dell'account; (4) l'anteprima "Signature as sent" mostra la firma con l'aspetto di Gmail; mandarsi un messaggio e confrontarlo con uno mandato da Gmail web: stessi caratteri, colori, link e tabelle (le immagini sono tolte); (5) modificando a mano la firma nel testo, parte in testo semplice; (6) rispondere a un proprio messaggio già firmato: l'aspetto ricco è sulla firma nuova, non su quella citata; (7) cambiare la firma su Gmail web: entro cinque minuti, aprendo una nuova finestra di composizione, DreaMail la aggiorna; una firma scritta in DreaMail non viene toccata; una tolta su Gmail resta con "No longer on Gmail"; (8) rimuovendo l'account spariscono anche le sue firme (DEC-019).
- ☐ **C-62** Menu dell'etichetta come Gmail (PR #78): (1) passando il mouse su un'etichetta della barra laterale compare "⋮" al posto del conteggio; sull'etichetta aperta sta accanto al conteggio; stesso menu col clic destro; un clic su "⋮" non riapre l'etichetta; (2) Label color → "Choose color…": la tavolozza si apre in una finestra, Esc e Done la chiudono; cambiando colore a un'etichetta genitore cambiano tutte le annidate, a ogni livello; poi una figlia può avere un colore suo, che resta finché non si cambia di nuovo il genitore; "Remove color" toglie il colore a tutta la famiglia; (3) In label list: Show / Show if unread / Hide, con il segno di spunta; In message list: Hide toglie l'etichetta dalle righe dell'elenco; (4) Edit: rinominare un genitore su un account vero e controllare su Gmail web che le figlie abbiano il nuovo percorso (comportamento del server non verificato: da provare una volta); "Nest label under" la sposta con le figlie; (5) Add sublabel: la nuova prende il colore del genitore; (6) Remove label: la conferma nomina le sottoetichette e le viste salvate che spariscono, Cancel è il predefinito; dopo, le conversazioni restano e l'etichetta è sparita anche su Gmail web; una vista salvata che la escludeva soltanto resta, senza quel filtro; (7) senza rete ogni voce dice "You're offline" e non fa nulla; (8) in "All accounts" ogni azione riguarda l'account della riga.
- ☐ **C-63** Barra degli account a "L" rovesciata (PR #81; sostituisce in C-59 la larghezza di 90 pt e la soglia di 1170 pt): (1) la striscia degli account è larga 64 pt, giusta per gli avatar; (2) in alto una fascia dello stesso colore va dal bordo sinistro della finestra, sotto chiudi/riduci/ingrandisci, fino al bordo destro della barra laterale, senza stacco con la striscia; il pulsante che nasconde la barra laterale sta sulla fascia; (3) trascinando il bordo della barra laterale la fascia la segue; (4) nascondendo la barra laterale la fascia resta larga quanto basta per i tre pulsanti (90 pt); (5) aprendo una conversazione e tornando indietro la fascia è ancora al suo posto; (6) guardare in chiaro e in scuro, a schermo intero e durante l'animazione mostra/nascondi (non verificabili senza un Mac: i test controllano le posizioni, non i pixel); (7) sotto 1144 pt la finestra passa al layout compatto.
- ☐ **C-64** Prima sincronizzazione visibile subito e "Connecting…" (PR #82), su un account vero: (1) Settings → Accounts → "Add Google Account…": compare "Connecting…" con "Cancel"; Cancel riporta il pulsante, senza errore e senza account aggiunto; (2) aggiungere l'account con "Keep mail from: Last 90 days": chiuso il browser il pulsante torna subito "Add Google Account…"; le righe dell'Inbox compaiono in pochi secondi, le più recenti per prime, mentre l'indicatore dice "Fetched N messages…"; l'elenco non salta e la selezione resta; (3) durante lo scaricamento archiviare, mettere la stella, segnare letto, etichettare ed eliminare qualche conversazione: restano come lasciate alla fine e dopo il controllo successivo; (4) nessuna raffica di notifiche per la posta vecchia; un messaggio nuovo notifica; (5) chiudere l'app a metà e riaprirla: riprende senza riscaricare, le righe ci sono e le azioni fatte prima restano; (6) rimuovere l'account durante la prima sincronizzazione: sparisce del tutto (DEC-019); (7) allargare "Keep mail from": la posta più vecchia compare man mano, senza notifiche; (8) rimuovere un account e riautorizzarlo subito: non ricompare vuoto.
- ☐ **C-65** Organize Labels per famiglie (PR #86): (1) le annidate stanno sotto la madre, rientrate, col nome corto; (2) trascinando una madre tutta la famiglia si sposta con lei e tiene l'ordine interno (mentre si trascina si muove solo la riga presa; la famiglia si sistema al rilascio: non verificabile senza un Mac); (3) un'annidata si riordina solo tra le sorelle: lasciata fuori dal blocco torna al suo posto; (4) un'etichetta di primo livello non entra in un'altra famiglia; (5) l'ordine è lo stesso nella barra laterale, nel selettore `l` e in Go ▸ Labels; (6) i colori e il colore ereditato dalle annidate funzionano come prima.
- ☐ **C-66** Tasti dietro le finestre e categorie (PR #83; sostituisce C-57 per le categorie): (1) "+" accanto a Labels → nella finestra "nuova etichetta" scrivere lettere che sono scorciatoie (e, #, j): nell'elenco dietro non succede nulla; Esc chiude la finestra; (2) lo stesso in Organize Labels (Esc la chiude; con la tavolozza dei colori aperta Esc non agisce sulla finestra dietro), nelle finestre di firme e filtri e nelle conferme del menu "⋮"; (3) in composizione, con la conferma "Discard" aperta, Esc annulla la conferma (prima salvava e chiudeva); (4) sotto "More": Scheduled e Reminders (se presenti), poi Promotions e Social come righe dirette, poi Spam; nessuna riga "Categories"; (5) `g p` apre Promotions anche con "More" chiuso (la riga resta nascosta: C-70, che sostituisce la regola "con Less la vista aperta resta visibile"); (6) non verificabile senza un Mac: avvisi e conferme di sistema, tasti premuti durante l'animazione di apertura di una finestra.
- ☐ **C-67** Firma ricca in composizione e incollata (PR #85; sostituisce in C-61 il passo 4 sull'anteprima "Signature as sent"): (1) nuovo messaggio con una firma di Gmail: la firma compare una volta sola, come riquadro non modificabile col suo aspetto sotto il testo; nessuna copia in testo e nessuna etichetta "Signature as sent"; (2) menu a penna → "Edit signature as text": il riquadro diventa testo modificabile e il messaggio parte in testo semplice; "No signature" lo toglie, un'altra firma lo sostituisce; (3) mandarsi un nuovo messaggio, una risposta e un inoltro: la firma c'è una volta sola, con l'aspetto di Gmail, prima del testo citato; (4) salvare una bozza con firma ricca, chiuderla e riaprirla (anche un inoltro): il riquadro torna e l'invio mantiene aspetto e messaggio inoltrato; (5) invio programmato e annulla invio con firma ricca: stesso risultato; (6) Settings → Signatures → nuova firma: incollare (⌘V) una firma copiata dalla pagina impostazioni di Gmail in un riquadro vuoto: l'aspetto compare sopra il testo, le immagini sono tolte e contate; modificare il testo o "Remove formatting" la rende semplice; (7) incollare in mezzo a un testo esistente incolla testo semplice; (8) non verificato senza un Mac: se Gmail toglie lo spazio di "-- " nelle bozze; con il testo citato espanso il riquadro sta sotto la citazione, mentre nel messaggio inviato la firma è prima.
- ☐ **C-68** Foto sui propri messaggi (PR #90): con due account, di cui uno ha come indirizzo "send as" l'indirizzo dell'altro: (1) nell'account A aprire una conversazione con un messaggio inviato da A con quell'indirizzo: accanto al messaggio c'è la foto (o l'iniziale) di A, non di B; (2) lo stesso nell'account B; (3) nella vista "tutti gli account" ogni messaggio inviato mostra la foto del proprio account; (4) un messaggio ricevuto da quell'indirizzo mostra il disco con l'iniziale, come prima.
- ☐ **C-69** Badge del Dock alla chiusura (PR #88): (1) con messaggi non letti e il numero sull'icona, chiudere l'app con ⌘Q: il numero sparisce dall'icona nel Dock e non torna; (2) riaprire: il numero giusto ricompare da solo, prima della sincronizzazione; (3) forzare l'uscita (⌥⌘Esc) con il numero visibile: resta finché l'app è chiusa (limite noto), ma al riavvio viene corretto subito; (4) la chiusura non resta mai bloccata (attesa di al più un secondo).
- ☐ **C-70** Barra laterale: ordine e "More" (PR #89; sostituisce in C-66 la regola "con Less la vista aperta resta visibile"): (1) trascinare Sent sopra Inbox: l'ordine cambia e resta dopo il riavvio; (2) aprire "More" e trascinare Promotions sopra Drafts: resta sempre visibile; trascinare Trash sotto "More": sparisce con "More" chiuso; (3) passare a un altro account: ha il suo ordine; la vista "tutti gli account" ha il proprio; (4) View → "Reset Sidebar Order" (o clic destro su una vista): torna l'ordine di Gmail solo per l'account mostrato; (5) aprire Spam e chiudere "More": la riga Spam sparisce, l'elenco a destra resta su Spam; lo stesso per un'etichetta sotto il "More" delle etichette; (6) trascinare fuori tutto: la riga "More" resta e si può rimettere una vista sotto; (7) con Reminders lasciata sotto "More" e un promemoria attivo: Reminders compare sopra "More" (DEC-063); (8) rimuovere un account: il suo ordine è dimenticato; (9) non verificato senza un Mac: il clic semplice su una riga seleziona ancora senza avviare un trascinamento; VoiceOver.
- ☐ **C-71** Densità (PR #87): (1) Settings → Appearance → "List density" → Compact: le righe dell'elenco si accorciano subito (circa 27 pt invece di 35), caratteri e icone uguali, intestazioni "Today"/"Yesterday" invariate; (2) passando col mouse i pulsanti di azione restano dentro la riga e si cliccano; riga selezionata e riga sotto il mouse hanno un aspetto corretto; (3) "Sidebar density" → Compact (corretta in PR #92: prima non cambiava nulla): righe della barra laterale più basse di circa 7 pt; icone, etichette colorate, testo, conteggi e "Add view" della stessa dimensione di prima; provare anche con "Dimensione icone barra laterale" di macOS su Piccola e Grande; le due scelte sono indipendenti; (4) entrambe restano dopo il riavvio; Comfortable è identico a prima; (5) con testo ingrandito (⌘+) Compact resta leggibile.
- ☐ **C-72** Selezione che resta colorata e ritocchi (PR #84, macOS 26): (1) aprire una conversazione, poi cliccare un'altra cartella nella barra laterale o un'altra finestra: la riga aperta resta nel colore accent (non grigio scuro), col testo leggibile; lo stesso per la riga della barra laterale e in Settings; (2) con accent predefinito e con uno personalizzato (rosso, giallo); (3) la lista che ha il fuoco della tastiera mostra una barretta sottile sul bordo sinistro della riga selezionata; (4) "+" accanto a Labels: più grande, grigio; (5) "⋮" di un'etichetta: verticale, grigio (bianco sull'etichetta aperta), **si clicca davvero col mouse e apre il menu** (nei test il clic è fatto per coordinate: da confermare a mano); non è tagliato dal bordo destro; (6) pulsanti di azione al passaggio del mouse su una riga: leggermente più distanziati, nessuno tagliato; (7) Settings → Signatures → Defaults: colonne allineate, menu larghi uguali.
- ☐ **C-73** Ritocchi (PR #92): (1) la finestra delle impostazioni si chiama solo "Settings", anche dopo aver cambiato pannello e averla riaperta; (2) etichette: aprendo "More" nessuna etichetta già visibile è ripetuta; una sottoetichetta nascosta di un'etichetta visibile compare una volta col nome completo ("madre/figlia"); menu "⋮", colore, conteggio e selezione funzionano su quella riga; (3) "+" accanto a Labels grande come il "+" di "Add view"; (4) "⋮": tre puntini piccoli, non più alti del testo, non tagliati a destra, bianchi sull'etichetta aperta, e si cliccano; (5) Settings → Signatures → Defaults: menu allineati a sinistra sotto le intestazioni, tutti larghi uguali; con due firme dallo stesso nome, scegliere la seconda salva la seconda.
- ☐ **C-74** Snooze e lingua del Mac (PR #93, Mac in italiano): nel campo snooze "fri", "sat", "sun", "sep" danno suggerimenti; "ven", "sab", "set 12", "venerdi" (senza accento) anche; i titoli sono in inglese ("Friday", "September 12"); "mar 5" propone per primo March 5, poi martedì alle 05:00; "fri 20" resta venerdì alle 20:00.
- ☐ **C-75** Barra laterale ridotta a icone (PR #94): (1) nascondere la barra laterale (pulsante o ←): resta una striscia di icone larga 40 pt accanto alla barra degli account, con Search, le viste nel proprio ordine e "More"; il bordo destro della striscia coincide con quello della fascia in alto (nessun dislivello); (2) clic su un'icona apre la vista; l'icona della vista aperta è evidenziata; passando col mouse compare nome e non letti ("Inbox, 12 unread"); (3) icona Search: riapre la barra intera col campo di ricerca attivo; (4) freccia "More": mostra/nasconde le icone delle viste sotto; (5) → o il pulsante riporta la barra intera alla larghezza di prima; lo stato resta dopo il riavvio; (6) finestra larga circa 1160 pt: riducendo la barra il pannello di lettura NON sparisce; (7) conversazione a tutta finestra e composizione affiancata: niente striscia, fascia in alto di 90 pt, pulsanti della finestra cliccabili; (8) la finestra si trascina ancora dalla fascia in alto; (9) con tre monitor e con "Dimensione icone barra laterale" Grande: aspetto corretto; (10) anteprima al centro: la striscia è oscurata come l'elenco.

## Ondata 3 — parità Gmail

- Creazione e modifica dei filtri server-side.
- Gestione dei colori delle label: la visualizzazione con i colori di Gmail è fatta (PR #25); resta la modifica dei colori su Gmail dall'app.
- Verifica ICS/RSVP su inviti reali e gap analysis rispetto a Postie.
- Snooze: richiede prima una scelta di progetto (allineamento con Gmail Web e mobile).

Avviata dal proprietario il 25 novembre 2026, prima che il cancello fosse completato: ogni step va comunque provato su un account reale, e i passi di prova stanno nel corpo di ciascuna PR.

| Step | Contenuto | Branch | Migrazione riservata |
|---|---|---|---|
| 3A | Creazione e modifica dei filtri lato server. Unito (#49), migrazione non usata. I filtri con inoltro restano da modificare su Gmail | `feature/gmail-server-filters` | v56 |
| 3B | Modifica dei colori delle label su Gmail. Unito (#48), migrazione non usata | `feature/gmail-label-color-editing` | v57 |
| 3C | Verifica ICS/RSVP e analisi delle lacune. Unito (#51) | `feature/ics-rsvp-verification` | v59 |
| 3D | Snooze: variante B scelta dal proprietario (DEC-041). Unito (#47) | `feature/snooze-gmail-alignment` | v60 |
| 3E | Azioni mancanti degli shortcut di Gmail. Unito (#50), migrazione non usata. Non collegati: `g k`, `g c` (mancano le viste), ⌘U, ⌘⇧7, ⌘[ / ⌘], ⌘\ (servono funzioni nuove dell'editor) | `feature/gmail-shortcut-actions` | v58 |

## Ondata 4 — Calendar e PGP

Avviata dal proprietario il 25 novembre 2026, in parallelo all'ondata 3. Ogni step parte da un progetto con opzioni e costruisce intanto solo le fondamenta che non dipendono dalla scelta, dietro un interruttore di build spento.

| Step | Contenuto | Branch | Migrazione riservata | Stato della decisione |
|---|---|---|---|---|
| 4A | Google Calendar | `feature/google-calendar-integration` | v61 | Perimetro B scelto (DEC-042) |
| 4B | PGP | `feature/openpgp-support` | v62 | Perimetro B scelto (DEC-045); libreria: rPGP approvata, previa verifica che non esista una soluzione già pronta (DEC-047) |

Google Calendar, perimetro B: disponibilità e conflitti accanto a un invito, risposta scritta direttamente sul calendario, "aggiungi al calendario". Richiede un secondo consenso Google separato, solo per Calendar; l'accesso a Gmail non cambia. Confermato dal proprietario: risposta solo sul calendario per gli eventi già presenti in Google Calendar ed e-mail per gli altri; calendari per i conflitti scelti dall'utente, con il principale come predefinito. Predefiniti adottati in assenza di indicazioni, ribaltabili: nessuna notifica degli eventi; in locale solo gli eventi degli inviti.

Google Calendar, lavoro futuro (non avviato):

- Perimetro C: agenda del giorno con sincronizzazione incrementale e promemoria (4–6 settimane dalla base di B; più dati personali in locale, notifiche).
- Perimetro D: creazione di eventi da un messaggio (oltre 6 settimane dalla base di B).

PGP, perimetro B: verifica delle firme, decifratura, import manuale delle chiavi. Predefiniti adottati, ribaltabili: chiavi private nel Keychain solo su questo Mac e protette da passphrase; nessuna copia su disco del testo decifrato; testo decifrato fuori dall'indice di ricerca. Libreria proposta: rPGP (Rust), da integrare con una PR separata. Il proprietario ha detto sì, a condizione che si verifichi prima che non esista una soluzione già pronta all'uso, ad esempio in Swift (DEC-047).

PGP, lavoro futuro (non avviato):

- Perimetro C: firma e cifratura in invio, generazione e revoca delle chiavi, bozze cifrate solo locali.
- Perimetro D: ricerca delle chiavi pubbliche in rete (WKD, keys.openpgp.org), Autocrypt, intestazioni protette.

## Lavori in sospeso

Aggiornato il 25 novembre 2026.

### Seguiti offerti, nessuno deciso

- Label prima dell'oggetto come in Gmail.
- Google Calendar, perimetri C e D (vedi "Ondata 4").
- PGP, perimetri C e D (vedi "Ondata 4").
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
| — | `perf/remote-image-cache` | #42 | Unito |
| — | `ux/custom-accent-color` | #43 | Unito |
| — | `docs/ux-round-4` | #44 | Documentazione del quarto giro |
| — | `feature/unread-dock-badge` | #45 | Unito |
| — | `docs/process-review-tiers` | #46 | Unito, modifica semplice |
| 3A–3E | vedi "Ondata 3" | — | In lavorazione dal 25 novembre 2026 |
| 4A–4B | vedi "Ondata 4" | — | In lavorazione dal 25 novembre 2026 |
| — | `ux/thread-row-hover-actions` | #52 | Unito |
| — | `ci/skip-duplicate-runs` | #53 | Unito dal proprietario, fuori flusso |
| 3C | `feature/ics-rsvp-verification` | #51 | Unito |
| 3B | `feature/gmail-label-color-editing` | #48 | Unito |
| 3E | `feature/gmail-shortcut-actions` | #50 | Unito |
| 3A | `feature/gmail-server-filters` | #49 | Unito |
| 4B | `feature/openpgp-support` | #54 | Unito (fondamenta senza libreria, dietro `MISHMAIL_PGP`) |
| 4B | `feature/openpgp-rpgp-engine` | #56 | Unito (solo la parte Swift, non collegata). Libreria nel repository `bateman/dreamail-openpgp` (PR 1 unita lì). Manca: rilascio della libreria (workflow Release, lanciato dal proprietario), commit con versione e checksum, poi una sessione nuova per collegamento, archivio delle chiavi, Keychain, migrazione v62 e interfaccia |
| 4A | `feature/google-calendar-integration` | #55 | Unito (logica, dietro `MISHMAIL_CALENDAR`) |
| 4A | `feature/google-calendar-ui` | #57 | Unito (interfaccia, dietro `MISHMAIL_CALENDAR`); da provare con account reali (C-45) |
| 3D | `feature/snooze-gmail-alignment` | #47 | Unito |
| — | `ux/account-avatar-unread-badge` | #58 | Unito |
| — | `perf/remote-image-cache-regression` | #59 | Unito: l'altezza del corpo si misura appena la pagina è pronta, senza aspettare le immagini. Innesco probabile del difetto: #40 (immagini remote per impostazione predefinita), non #42 |
| — | `ux/per-account-settings` | #60 | Unito |
| — | `ux/darker-section-headers` | #64 | Unito (livello semplice) |
| — | `chore/make-run-real-account-default` | #66 | Unito (livello semplice) |
| — | `feature/account-signatures` | #61 | Unito |
| — | `ux/account-rail` | #62 | Unito (livello basso rischio) |
| — | `ux/gmail-style-sidebar` | #63 | Unito (migrazione v65) |
| — | `ux/restore-window-size` | #65 | Unito (livello basso rischio) |
| — | `perf/remote-image-cache-regression` | #67 | Unito (livello basso rischio) |
| — | `feature/openpgp-library-wiring` | #68 | Unito (dietro `MISHMAIL_PGP`) |
| — | `chore/openpgp-library-0.1.1` | #72 | Unito (libreria v0.1.1: messaggi di GnuPG 2.4) |
| — | `chore/rename-dreamail` | #73 | Unito (DEC-065, DEC-069; libreria OpenPGP v0.2.0); da provare sul Mac (C-56) |
| — | `ux/categories-collapse-hides-selected` | #76 | Unito: "Categories" chiusa nasconde anche la categoria aperta (livello basso rischio) |
| — | `fix/remote-images-not-loading` | #75 | Unito: immagini `http://` e `//host` caricate in https, testo alternativo per le immagini fallite, diagnostica a soli conteggi |
| — | `ux/account-rail-polish` | #77 | Unito (livello basso rischio): barra a 90 pt, anello su "All accounts", interruttore per il "+" |
| — | `ux/label-picker-enter-applies` | #74 | Unito (livello basso rischio): Invio applica e chiude, Spazio spunta, "Create new" (tenuto su indicazione del proprietario) |
| — | `feature/signature-menu-auto-import` | #79 | Unito (migrazione v67): menu firme come Gmail, importazione automatica, aspetto della firma di Gmail nell'invio (DEC-070); da provare (C-61) |
| — | `feature/gmail-label-menu` | #78 | Unito (migrazione v66): menu dell'etichetta come Gmail, colore del genitore alle annidate (DEC-071); test UI con limite a 35 minuti; da provare (C-62) |
| — | `ux/account-rail-top-band` | #81 | Unito (livello basso rischio): striscia account a 64 pt sotto una fascia in alto fino al bordo della barra laterale; da provare (C-63) |
| — | `perf/first-sync-progressive` | #82 | Unito: posta visibile durante la prima sincronizzazione, azioni conservate, ripresa dopo interruzione, "Connecting…" con Cancel (DEC-072); da provare su un account vero (C-64) |
| — | `ci/faster-ui-tests` | #80 | Unito: test UI in due metà parallele da circa 13 minuti (prima un job da 22-27), meno avvii, elenco etichette demo corto dove non serve quello lungo; nessuna verifica tolta; limite 20 minuti per metà |
| — | `ux/organize-labels-families` | #86 | Unito (livello basso rischio): in Organize Labels le annidate stanno e si spostano con la madre; stesso ordine in selettore e vista Labels; da provare (C-65) |
| — | `fix/sidebar-sheet-escape-and-disclosure` | #83 | Unito (livello basso rischio): i tasti vanno alla finestra aperta (Esc la chiude, niente scorciatoie dietro); categorie come righe dirette sopra Spam (DEC-073); il triangolo di "Vendors" con elenco corto era un errore del test, non dell'app; da provare (C-66) |
| — | `ux/compose-rich-signature-block` | #85 | Unito (livello standard, migrazione v68): firma ricca mostrata una volta sola come riquadro col suo aspetto, "Edit signature as text", firma copiata da Gmail incollabile in Settings (DEC-074); da provare (C-67) |
| — | `fix/own-message-avatar-account` | #90 | Unito (livello basso rischio): la foto accanto a un proprio messaggio è quella dell'account in cui sta il messaggio, non del proprietario dell'indirizzo; da provare (C-68) |
| — | `fix/dock-badge-cleared-on-quit` | #88 | Unito (livello basso rischio): il numero sull'icona del Dock è tolto alla chiusura (attesa limitata a 1 s) e all'avvio dopo un'uscita forzata; da provare (C-69) |
| — | `ux/sidebar-reorder-system-views` | #89 | Unito (livello basso rischio): viste di sistema riordinabili col trascinamento, per account, anche attraverso "More"; "More" chiuso nasconde tutto (DEC-075); da provare (C-70) |
| — | `ux/list-density-compact` | #87 | Unito (livello basso rischio): densità Comfortable/Compact per l'elenco e, separata, per la barra laterale (DEC-076); da provare (C-71) |
| — | `fix/oauth-loopback-deadline-test-flaky` | #91 | Unito (solo test): il test instabile `OAuthLoopbackLimitsTests` contava come "chiusa dal server" una connessione di prova fallita in locale (porta ancora occupata dal test precedente); ora ritenta da un'altra porta e un test nuovo riproduce il caso. Nessuna modifica all'app |
| — | `ux/selection-stays-accent-and-sidebar-glyphs` | #84 | Unito (livello basso rischio): la riga aperta resta nel colore accent anche senza fuoco (macOS 26, DEC-077); "+" e "⋮" neutri, "⋮" verticale; più spazio tra le azioni al passaggio del mouse; tabella Defaults delle firme allineata; da provare (C-72) |
| — | `fix/snooze-parser-locale-independent` | #93 | Unito (livello basso rischio): lo snooze accetta sempre i nomi inglesi di giorni e mesi, oltre a quelli della lingua del Mac; titoli in inglese (DEC-078); da provare (C-74) |
| — | `fix/settings-title-sidebar-density-labels-more` | #92 | Unito (livello basso rischio): titolo "Settings"; densità Compact della barra laterale ora reale e misurata; "More" delle etichette senza doppioni (DEC-078); "+" e "⋮" ridimensionati; menu Defaults delle firme allineati; da provare (C-73) |
| — | `fix/settings-signatures-fit-window` | #97 | Unito (livello semplice, senza attendere la CI; CI su main verde dopo): la tabella Defaults delle firme introdotta da #92 era più larga del pannello e tagliava tutta la finestra Settings; colonne ristrette a 170 + 160 + 160 |
| — | `ux/sidebar-collapsed-icon-strip` | #94 | Unito (livello standard): la barra laterale nascosta diventa una striscia di sole icone allineata alla fascia in alto (DEC-079); da provare (C-75) |
| — | `test/settings-panes-fit-window` | #98 | Unito (solo test): un test UI apre ogni pannello di Settings e verifica che barra laterale e controlli stiano dentro la finestra (guardia dopo il difetto corretto da #97) |
| — | `docs/study-google-chat`, `docs/study-google-calendar`, `docs/study-rebranding-dreamail` | #69, #70, #71 | Uniti (studi in `docs/studi/`; domande aperte per il proprietario in fondo a ciascuno) |
