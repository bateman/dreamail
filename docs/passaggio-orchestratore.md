# Passaggio di consegne all'orchestratore

Scritto il 27 novembre 2026, sera, dal secondo orchestratore
(`session_019yj8YuvMDEjw2we3q2P1ah`) per la sessione che ne prende il posto.
Leggere prima `CLAUDE.md`: vale tutto, e qui non è ripetuto.

## Perché il passaggio

Lo ha deciso il proprietario, dopo una giornata che giudica inaccettabile:
circa dieci ore e molta spesa per modifiche piccole all'interfaccia, con
errori dell'orchestratore elencati più sotto. Il nuovo orchestratore lavora
con il modello Opus; il proprietario non vuole più il modello precedente.
Prima regola: **spendere poco e non aprire lavoro che lui non ha chiesto.**

Il primo orchestratore (`session_019yj8YsaN8QRX7nBhjqZ187`) era stato
sostituito perché aveva chiesto l'autorizzazione a collegarsi al Mac del
proprietario: da quel momento le sessioni di lavoro non riuscivano più a
scrivergli.

**Non chiedere mai quell'autorizzazione** (`confirm_repository_trust`,
collegamento a una cartella del Mac, messaggi a una sessione che gira sul Mac):
è irreversibile e toglie i messaggi delle sessioni. Il Mac del proprietario non
è comunque adatto come verifica automatica: lingua italiana, tre monitor,
permesso di registrazione dello schermo mancante; molti test falliscono lì
anche su `main`. Il proprietario invece prova a mano le build di `main` ed è
l'unico che vede davvero l'interfaccia.

I rapporti delle sessioni si leggono anche dalla trascrizione:
`list_events` con `kinds: ["result"]`.


## Chi è il proprietario e cosa si aspetta

- Scrive in italiano: rispondere sempre in italiano, in modo conciso.
- Prova con `git pull` e `make run` sul suo Mac (macOS 27, più monitor; la CI
  gira su macOS 26, un monitor, inglese). Spesso scrive dal telefono.
- Vuole le istruzioni di processo seguite alla lettera e nessuna imprecisione:
  dire sempre che cosa è verificato e che cosa no, e non dichiarare risolto ciò
  che non lo è.
- Riferimento di prodotto: **Gmail web**. Quando manda uno screenshot di Gmail,
  quello è il comportamento voluto. Prima di proporre una regola diversa,
  chiedersi perché l'app differisce da Gmail.
- Non attribuirgli mai un'interruzione; non chiedere né proporre di cancellare
  rami; mai "claude" nei nomi dei rami.
- Dati personali: indirizzi, nome, nomi delle sue etichette e mittenti visibili
  negli screenshot non vanno in codice, test, documenti, testi di PR né nei
  messaggi alle sessioni (usare nomi neutri ed `example.com`). I commit usano
  l'identità della sessione; dove serve nominarlo, `bateman@users.noreply.github.com`.

## Come si lavora

- Una sessione per lavoro, creata con `create_session` sul repository
  `https://github.com/bateman/dreamail`, con ramo d'uscita descrittivo.
  Le sessioni girano su Linux e non compilano Swift: aprono una PR in bozza e
  usano la CI macOS (`ci.yml`). I test UI partono solo con `workflow_dispatch`
  sul ramo, dopo che la run della PR è verde (stesso gruppo di concorrenza: una
  run può annullare l'altra; se la dispatch risulta annullata va rilanciata).
- Livelli (tabella in `CLAUDE.md`): Semplice (Sonnet, nessuna review, unione
  diretta), Basso rischio (Sonnet `claude-sonnet-5-5`, una review
  `ponytail-review` in modalità `full`), Standard (Opus `claude-opus-5-5`,
  effort medio, `ponytail-review` e `security-audit` in parallelo). Nel dubbio
  il più severo, dicendolo.
- Le review le lancia l'orchestratore, appena la run della PR è verde: agenti
  `general-purpose` in sola lettura, `isolation: worktree`, con le skill
  `dreamail:ponytail` (argomento `full`) poi `dreamail:ponytail-review`, e
  `dreamail:security-audit` in modalità guida. Dare al revisore il compito e i
  punti da controllare, non le conclusioni. Lanciare due agenti worktree nello
  stesso istante può far fallire la creazione del secondo: rilanciarlo.
- Triage in REQUIRED / SHOULD / ACCEPTED, invio alla sessione, **al più due
  giri**. Poi: controllo personale del diff finale, PR da bozza a pronta,
  squash-merge con `expectedHeadSha` di 40 caratteri, messaggio di chiusura,
  archiviazione della sessione, `workflow_dispatch` di `ci.yml` su `main`,
  documenti, avviso alle sessioni che toccano gli stessi file perché
  riallineino a `main`.
- I documenti li tiene l'orchestratore, non le sessioni: `CHANGELOG.md`
  (sezione Unreleased, in inglese), `docs/piano-sviluppo.md` (tabella di stato e
  lista di controllo manuale C-nn), `docs/registro-decisioni.md` (DEC-nnn, riga
  di versione, intestazione "Versione:"). Push con
  `git -c push.negotiate=true push origin HEAD:main`.
- Non indebolire mai test o controlli della CI; un cambio di comportamento può
  ripuntare un controllo ma ogni controllo esistente tiene una controparte
  (tabella vecchio → nuovo nel testo della PR).
- Decisioni di prodotto da non riaprire: IA/MCP spenti; aggiornamento
  automatico spento; "cancellato vuol dire sparito" (DEC-019, precisato da
  DEC-081); notifiche generiche; nessun log con dati di posta.

## Come accorgersi che una sessione ha finito

Le sessioni create da questa nuova sessione possono scriverle. In ogni caso non
contare solo sui messaggi: tenere un controllo in sottofondo (comando Bash con
`run_in_background`) che interroga GitHub ogni 90-120 secondi e termina al
primo esito di CI nuovo; il termine richiama l'orchestratore. Esempio di cosa
interrogare: `gh api repos/bateman/dreamail/pulls/N --jq .head.sha` e
`gh api "repos/bateman/dreamail/actions/runs?head_sha=SHA&event=workflow_dispatch"`.
I rapporti delle sessioni si leggono anche dalla trascrizione:
`list_events` con `kinds: ["result"]`.

## Errori dell'orchestratore uscente, da non ripetere

- Ha accettato "densità compatta" senza un test che misurasse la riga: non
  cambiava nulla. Per ogni modifica visibile serve un test che misuri l'effetto.
- Ha chiesto colonne a larghezza fissa senza fare il conto con la larghezza del
  pannello: Settings risultava tagliata. Chiedere sempre un controllo che il
  contenuto stia nel contenitore.
- Ha proposto regole proprie (percorso "madre/figlia", capsula rientrata,
  trattino del fuoco) al posto di ciò che il proprietario chiedeva o di ciò che
  fa Gmail: tutte rifatte. Seguire la sua indicazione e Gmail.
- Ha passato a una sessione i nomi reali delle etichette del proprietario,
  finiti nei test: poi tolti. Mai più.
- Ha dichiarato cause non verificate (posta "non scaricata", messaggi
  "mancanti"): la prima era la regola del Cestino, la seconda ipotesi (ora di invio al posto di quella di arrivo) è
  stata poi smentita dal codice. Formulare
  ipotesi come ipotesi e chiedere al proprietario il dato che decide.


### Errori del secondo orchestratore (27 novembre), da non ripetere

- **Ha lasciato costruire un progetto complicato per un compito semplice.** Il
  campo di ricerca accanto al nome della vista (#113) è stato fatto tre volte:
  disegnato sopra la fascia del titolo (non riceveva i clic), poi come
  elemento SwiftUI della barra (non riceveva il cursore da `/`), infine attorno
  a un `NSTextField`. Per una modifica d'interfaccia, pretendere prima la
  soluzione più ovvia e una prova minima (clic, tasto) prima del resto.
- **Ha dato per fatta una cosa vista solo nel codice.** Ha scritto al
  proprietario che il menu del clic destro aveva le icone: nel codice ogni
  voce ha un'icona, sul suo Mac non si vedono. Ciò che non è stato visto su un
  Mac si dichiara "non verificato", sempre.
- **Ha violato una regola appena data.** Dopo aver scritto "nessuna sessione
  nuova finché queste non sono chiuse" ne ha aperta una. Il proprietario l'ha
  fatta fermare.
- **Ha tenuto nove PR aperte insieme.** Si sono pestate i piedi (conflitti
  dopo ogni fusione, una build in più ogni volta) e hanno saturato la coda dei
  runner macOS. Poche PR per volta, e fondere nell'ordine in cui toccano gli
  stessi file.
- **Ha fuso un test mai eseguito nella forma finale** (#112): `main` è andato
  in rosso e c'è voluta la #125. Dopo aver cambiato un test UI, o si riesegue
  o non si fonde.
- **Ha aperto un'indagine su un difetto che non esisteva** (#122: ⌘Z dopo
  "Trash"): era il test, per il toast scaduto e per il layout compatto. Sullo
  schermo della CI (1024 pt) l'app è in layout compatto e una conversazione
  aperta sostituisce l'elenco: molti test UI nuovi sbagliano per questo.
- **Ha lasciato che una sessione allargasse il compito** ("Label as" su più
  conversazioni nella #123, non richiesto): la revisione vi ha trovato due
  difetti veri.
- **Ha scritto al proprietario a ogni evento**, in una conversazione
  lunghissima: ogni messaggio rilegge tutto il contesto e costa. Scrivere solo
  a fusione avvenuta o quando serve una sua decisione.
- Ha lanciato una corsa UI sopra quella di una sessione, annullandola: prima
  di lanciare per conto di una sessione, controllare la corsa per id.

## Stato al momento del passaggio

`main` è a `2a88274`; **CI completa verde su quel commit** (corsa
46066576429: build, test unitari, tre shard UI). Ultimi numeri usati:
**C-95**, **DEC-091**, registro versione **0.47**, migrazione **v71**. I
prossimi sono C-96, DEC-092, 0.48, v72.

Unite il 27 novembre da questo orchestratore (dettagli nel changelog e nel
piano): #108, #109, #111, #114, #117, #118, #116, #119, #120, #115, #121,
#112, #110, #113, #123, #122, #125. La #107 è del primo orchestratore.

Nessuna sessione di lavoro è attiva: tutte archiviate. Nessuna corsa in coda.

### Lavori aperti

- **PR #124** `fix/row-menu-icons-shown`, in bozza, sessione fermata dal
  proprietario dopo un minuto (`session_019yj8YtFLRdmKKDtR8mPG9c`,
  archiviata). Contiene poche righe per far comparire le icone nel menu del
  clic destro (ipotesi non verificata: nei menu di macOS una `Label` mostra
  solo il testo se non si chiede `.labelStyle(.titleAndIcon)`). **Non
  toccarla senza che il proprietario lo chieda.** Lo stesso difetto può
  riguardare il menu "⋮" dei messaggi (#110) e gli altri menu.
- **Campo di ricerca (#113)**: il proprietario lo ha visto e lo giudica
  brutto e non conforme a ciò che voleva ("non hai capito"). Non ha ancora
  detto che cosa non va: chiederglielo con una domanda sola e precisa,
  possibilmente partendo da una sua schermata, prima di cambiare qualsiasi
  cosa. La sua richiesta era: campo accanto alla scritta della vista, che si
  restringe quando si restringe la colonna dell'elenco.
- **Colori delle etichette**: la #118 è una diagnostica, il difetto NON è
  risolto. Serve dal proprietario la riga "Current:" di un'etichetta che in
  Gmail web ha un colore e qui no (prova C-88): "preset NOME" vuol dire che
  Gmail manda il preset; "no preset (list and get)" che non lo manda e serve
  un'altra strada.

### Rimandati, da non avviare senza richiesta

- "Print" nel menu del messaggio: il proprietario ha detto di aggiungere il
  permesso di stampa (`com.apple.security.print`); livello standard.
- "Find emails from" non è offerto per indirizzi con `_`, `%`, `*`: vanno
  trattati come caratteri normali nella ricerca locale; nello stesso lavoro
  unire i due controlli sugli indirizzi (`filterFromAddress` della #110 e
  `strictAddress` della #116).
- "Forward as attachment" e "Open in new window" mancano dal menu del clic
  destro (mancano i mattoni nell'app).
- Toast di annullamento di 3,5 s: forse pochi; non confrontato con Gmail.
- Cestinare una riga solo evidenziata apre la conversazione successiva: da
  confrontare con Gmail.
- La stella nell'elenco stella tutti i messaggi della conversazione; Gmail
  web solo l'ultimo.
- "Delete" (menu di riga) contro "Trash" altrove: una parola sola, da
  decidere col proprietario.
- Libreria OpenPGP: rPGP 0.21.1 rifiuta circa una chiave Ed25519 su 256
  (seme che comincia per 0x00) e rende instabili l'1,2 % delle corse di
  `RPGPLinkedTests`. Correggerlo richiede il repository
  `bateman/dreamail-openpgp` con permesso di scrittura; segnalarlo a rPGP è
  un'azione pubblica e serve il sì del proprietario.
- CI: compilare i test UI nella corsa della PR; capire quali avvisi sono
  errori; altri test con la lettura al bordo dell'area visibile
  (`SidebarLabelTreeUITests`, `SidebarLabelMenuUITests`,
  `ThreadMessageRowsUITests`); togliere l'indice inutilizzato
  `thread_unread_primary_inbox` in una migrazione futura.

### Punti aperti col proprietario

- Prove manuali da fare sul suo Mac: C-83 … C-95 nel piano. Le più utili:
  C-88 (riga "Current:"), le icone nei menu, C-86 (fascia grigia nel tema
  chiaro), C-92 (una sola riga selezionata nella barra laterale), C-94
  (ricerca).
- Ha chiesto un rimborso ad Anthropic per il consumo del 27 novembre;
  l'orchestratore non può concederlo né ha accesso alla fatturazione.
- È molto arrabbiato per costi e tempi. Risposte brevi, in italiano, fatti
  verificati distinti da quelli no, niente aggiornamenti intermedi.
