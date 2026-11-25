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
- ☐ **C-41** Colore delle label su Gmail (PR #48): MishMail → Organize Labels → clic sul pallino di una label utente → "Color on Gmail"; il colore compare subito e, entro un minuto, su Gmail web e telefono; dopo una sync non torna indietro; "No color on Gmail" toglie davvero il colore (non verificato: la documentazione non lo dice); senza rete torna il colore vecchio con un avviso; il colore solo-Mac resta prevalente. Passi completi nel corpo della PR #48.
- ☐ **C-42** Shortcut di Gmail (PR #50): `m` silenzia davvero su un account reale e `m` di nuovo toglie il silenzio (non verificato: l'API di Gmail potrebbe rifiutare la label `MUTED`; in quel caso la conversazione torna con un avviso); `+` / `-` importanza; `v` sposta, anche da una vista label, dal Cestino, con righe spuntate di due account e dalla barra della conversazione con altre righe spuntate; `n` / `p` / `;` / `:` in una conversazione; tutti i tasti su tastiera italiana. Passi completi nel corpo della PR #50.
- ☐ **C-43** Filtri Gmail (PR #49): MishMail → ⌘, → Gmail filters; creare un filtro, modificarlo, cancellarlo e ritrovare lo stesso risultato su Gmail web; anteprima dei messaggi corrispondenti; conferma prima di salvare un filtro che cancella o salta la Inbox; messaggio di Gmail per un filtro già esistente; un filtro con inoltro non è modificabile ma si può cancellare; soglia di dimensione in MB. Passi completi nel corpo della PR #49.
- ☐ **C-44** Snooze allineato a Gmail (PR #47): posticipare una conversazione su Gmail web, poi Sync in MishMail: compare sotto Snoozed con "Snoozed in Gmail" e non è in Inbox (non verificato da nessuno: che l'API di Gmail accetti `in:snoozed` e restituisca solo la posta posticipata); "Unsnooze" su Gmail web la riporta in Inbox dopo la sync; posticipare in MishMail su un account di prova e rimuovere l'account: su Gmail web la conversazione è di nuovo in Inbox; senza rete la rimozione si completa e un avviso dice quante sono rimaste archiviate. Passi completi nel corpo della PR #47.
- ☐ **C-45** Google Calendar (PR #55 e #57, solo con `MISHMAIL_CALENDAR = YES` in `Local.xcconfig`, da provare quando l'interfaccia è unita): consenso reale; risposta a un invito di un organizzatore Google (deve ricevere una sola notifica: non verificato); risposta a un invito Outlook; "Add to Google Calendar" su un evento già presente (non verificato cosa fa Google con un identificativo esistente); rimozione dell'account: permesso e calendari scelti spariscono.
- ☐ **C-46** Azioni al passaggio del mouse (PR #52): con il mouse su una riga della lista compaiono, da sinistra, archivia, cestina, segna come non letta/letta, posticipa; ciascuna agisce su quella riga senza aprire la conversazione; la stella è a sinistra del mittente; la data non è tagliata con testo grande; la riga non salta entrando e uscendo con il mouse; resa con il pannello di lettura aperto (lista stretta).
- ☐ **C-47** Badge dei non letti per account (PR #58): nel selettore degli account ogni foto profilo ha il suo numero in alto a destra, sopra l'anello; sparisce a zero; "99+" oltre 99; nessun badge su "tutti gli account"; la somma coincide con il Dock se il badge del Dock conta tutti gli account; alone e contrasto in modalità chiara e scura.
- ☐ **C-48** Impostazioni per account (PR #60): MishMail → ⌘, → Accounts: ogni account ha il proprio interruttore "Show sender and subject in notifications" (gli account esistenti mantengono la scelta di prima); con l'interruttore acceso su un account e spento su un altro, le notifiche del secondo restano generiche; spegnendolo, le notifiche già consegnate di quell'account spariscono dal Centro notifiche (non verificato contro un vero Centro notifiche); "Show Filters…" apre i filtri di quell'account.
- ☐ **C-49** Intestazioni della lista più scure (PR #64) e `make run` con l'account reale (PR #66): "Today", "Yesterday" e le altre sono più scure di mittente e oggetto dei messaggi letti, in modalità chiara e scura; `make run` apre l'account reale, `make run DEMO=1` la casella finta.
- ☐ **C-50** Firme per account (PR #61): MishMail → Settings (⌘,) → Signatures. Creare due firme, impostare la predefinita per i nuovi messaggi e per le risposte di ogni indirizzo; "Import from Gmail" porta le firme di Gmail (una firma con tabella resta leggibile, le immagini sono tolte e la cosa è detta). In composizione: la firma predefinita compare da sola; cambiando From la firma cambia; il menu "Insert signature / No signature / Manage signatures" la sostituisce o la toglie; un P.S. scritto sotto la firma non viene cancellato; ⌘Z annulla il cambio.
- ☐ **C-51** Immagini fallite nascoste (PR #67): aprire la ricevuta SumUp: al posto del "?" blu non compare nulla. Da guardare: un'immagine fallita con testo alternativo e dimensioni fisse potrebbe mostrare ancora il "?" (non verificato).
- ☐ **C-52** Barra degli account (PR #62): striscia sempre visibile a sinistra della barra laterale. Un avatar per account con il suo numero di non letti; clic cambia account; "All accounts" in cima con più account; "+" aggiunge un account; ingranaggio in basso apre Settings. ⌘1…⌘9 come prima; trascinare un avatar riordina gli account; colori in modalità chiara e scura; gli avvisi in basso (annulla) non coprono l'ingranaggio; con un solo account l'avatar appare selezionato.
- ☐ **C-53** Dimensione della finestra all'avvio (PR #65): ridimensionare e spostare la finestra principale, uscire con ⌘Q, riaprire: la finestra torna con la stessa dimensione e posizione. La prima volta dopo l'aggiornamento parte con la dimensione predefinita (il nome di salvataggio è cambiato). Provare anche con `make run` dopo una ricompilazione.
- ☐ **C-54** Barra laterale come Gmail (PR #63): (1) viste di sistema nell'ordine di Gmail: Inbox, Starred, Snoozed, Important, Sent, Drafts, All Mail, Trash, poi "More"; (2) "More" apre Spam, Categories e, se presenti, Scheduled; resta com'era dopo ⌘Q; (3) sotto "Labels" le etichette ad albero come in Gmail, con colore e non letti; un genitore aperto resta aperto dopo il riavvio; (4) un'etichetta nascosta in Gmail sta sotto il "More" delle etichette; (5) "+" accanto a Labels: creare `test`, poi `test2` annidata sotto `test`; entrambe compaiono in Gmail web; (6) con tutti gli account: un albero per account; aprire un'etichetta dell'account A e passare a B dalla barra porta alla Inbox di B; (7) `g l` e Go ▸ Labels aprono ancora la vista di tutte le etichette; (8) Spam mostra solo lo spam arrivato da quando l'account è stato aggiunto. Non verificato senza Mac: etichette reali con "mostra se non lette"/"nascondi", resa in modalità scura, creazione reale su Gmail.

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
| — | `feature/openpgp-library-wiring` | #68 | In lavorazione (libreria v0.1.0, commit `adad8a1`) |
| — | `docs/study-google-chat`, `docs/study-google-calendar`, `docs/study-rebranding-dreamail` | #69, #70, #71 | Uniti (studi in `docs/studi/`; domande aperte per il proprietario in fondo a ciascuno) |
