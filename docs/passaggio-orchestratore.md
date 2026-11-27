# Passaggio di consegne all'orchestratore

Scritto il 27 novembre 2026 dall'orchestratore uscente
(`session_019yj8YsaN8QRX7nBhjqZ187`) per la sessione che ne prende il posto.
Leggere prima `CLAUDE.md`: vale tutto, e qui non è ripetuto.

## Perché il passaggio

La sessione uscente ha chiesto al proprietario l'autorizzazione a collegarsi al
suo Mac. Da quel momento è legata in modo permanente ai suoi dispositivi
fidati: le sessioni di lavoro non riescono più a scriverle (`send_message`
rifiutato) e i promemoria programmati (`send_later`) non le arrivano. Una
sessione nuova non ha questo limite.

**Non chiedere mai quell'autorizzazione** (`confirm_repository_trust`,
collegamento a una cartella del Mac, messaggi a una sessione che gira sul Mac):
è irreversibile e toglie i messaggi delle sessioni. Il Mac del proprietario non
è comunque adatto come verifica: lingua italiana, tre monitor, permesso di
registrazione dello schermo mancante; molti test falliscono lì anche su `main`.

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

## Stato al momento del passaggio

`main` è a `12e0db3` (codice `0e1bf63`, PR #106); CI completa verde, test UI
compresi. Ultimi numeri usati: **C-82**, **DEC-082**, registro versione
**0.37**, migrazione **v70**. I prossimi sono C-83, DEC-083, 0.38, v71.

Unite il 26-27 novembre (dettagli nel changelog e nel piano): #84, #85, #87-#94,
#97-#106.

### Lavori aperti

| PR | Ramo | Sessione | Livello | Cosa | Stato |
|---|---|---|---|---|---|
| #108 | `fix/label-gmail-color-missing` | `session_019yj8YsiQKRQF3uC3vbUH5g` | Basso rischio | Colori delle etichette mancanti (vedi sotto) | **Passa al nuovo orchestratore.** In lavorazione, CI in corso |
| #107 | `ux/deleted-messages-in-conversation` | `session_019yj8YuKTzb2MXdQPfTxCHj` | Standard | Riga "N deleted messages · View" nella conversazione viva, come Gmail; "Restore" per messaggio | Resta all'orchestratore uscente fino all'unione |
| nessuna | `fix/message-time-gmail-internal-date` | `session_019yj8YrFF9oGNYu2RPVyZst` | Basso rischio | Ora dei messaggi diversa da Gmail | **Ipotesi smentita, nessuna modifica**: il codice usa già `internalDate` (`MessageParsing.swift`); nessun punto legge l'intestazione `Date`. Causa ignota; servono dal proprietario, per 2-3 conversazioni, l'ora in Gmail e quella in DreaMail e se la conversazione ha un messaggio più recente in bozza, Cestino o Spam |

L'orchestratore uscente chiude #107 e ne registra i documenti; il nuovo non li tocca, salvo diversa indicazione del proprietario.
Per evitare due scritture concorrenti sui documenti: prima di ogni modifica a
`CHANGELOG.md` e `docs/`, `git fetch` e ripartire da `origin/main`.

### Compito assegnato: i colori delle etichette (#108)

Difetto aperto da due PR (#100, #103) senza causa trovata. Sul conto del
proprietario alcune etichette che in Gmail web hanno un colore (un grigio
scuro su due etichette, un verde medio, un oliva, un rosso, un grigio-blu)
sono disegnate senza colore nella barra laterale; le altre mostrano il colore
di Gmail. Dopo #103 e una sincronizzazione il difetto resta.

Cosa è già stato escluso o fatto:
- ogni `#rrggbb` in `LabelRow.gmailBackgroundColor` è disegnato pieno
  (`LabelPillStyle.resolve`); nessuna tabella di colori ammessi in lettura;
- un'etichetta senza colore è disegnata col solo contorno;
- per le etichette che `labels.list` restituisce senza colore si richiede
  `labels.get` (`SyncEngine.completingColors`);
- nessuna cache HTTP sulla richiesta delle etichette.

Dato nuovo dal proprietario (tema scuro): nella finestra "Label color" nessun
campione è spuntato né per un'etichetta difettosa né per una disegnata
correttamente in azzurro; per un'altra corretta (oro) la spunta c'era. Quindi
"nessuna spunta" non vuol dire "nessun colore": la griglia ha 64 colori, Gmail
di più. La finestra non mostra cosa c'è in archivio.

Piste date alla sessione: (1) riga "Current: #codice / none" nella finestra,
che è anche la prova che manca; (2) i colori difettosi sono quasi tutti scuri o
poco saturi: cercare una regola di disegno della barra laterale che li renda
come "senza colore" nei due temi; (3) decodifica di `color` che fallisce per
intero; (4) `completingColors` che non parte o non viene unito.

Primo rapporto della sessione (PR #108, non ancora verificato da una review):
- causa trovata **solo per i grigi scuri nel tema scuro**: il pallino della
  barra laterale (`shape: .dot`) sotto una differenza minima di 25 dallo sfondo
  (`minimumDotEdgeDifference`) riceve un contorno grigio su un riempimento quasi
  invisibile, che si legge come "senza colore". La PR lo sostituisce con un
  riempimento sempre visibile (`LabelPillStyle.visibleTagFill`);
- verde, oliva, rosso e grigio-blu **restano senza causa**;
- la griglia mostra 64 dei 102 colori documentati di Gmail: per gli altri 38
  nessun campione è spuntato, e questo spiega l'azzurro senza spunta;
- la PR aggiunge la riga "Current: #codice / none" nella finestra;
- pista non chiusa: una voce di `labels.list` con `type` assente è esclusa da
  `completingColors` ma salvata come etichetta utente.

Cosa fare: seguire la sessione (leggerne il rapporto, che inizia con
`REPORT FOR ORCHESTRATOR`; avvisarla con `send_message` che l'orchestratore è
cambiato e dare il proprio identificativo), lanciare la review quando la run
della PR è verde, non accettare "risolto" senza una causa dimostrata o senza
che il proprietario lo confermi sul suo conto. Se la causa non emerge dal
codice, unire la riga "Current:" e chiedere al proprietario di leggerla su una
delle etichette difettose: quel valore decide tra "non in archivio" e "in
archivio ma disegnato come assente".

### Punti aperti col proprietario

- Colori delle etichette (sopra).
- Selezione squadrata della barra laterale (#102): restano 8 pt di sfondo a
  sinistra, margine di sistema della colonna; deve dire se va bene.
- Visibilità di una sottoetichetta diversa tra Gmail e DreaMail: ora non ha più
  effetto sulla barra laterale (famiglie intere, DEC-080); il proprietario ha
  confermato che la sottoetichetta è visibile e l'ordine è quello di Gmail.
- Prove manuali C-67 … C-82 sul suo Mac, in gran parte ancora da fare.
- Se e come usare un Mac per compilare prima del push (oggi no: vedi sopra).
