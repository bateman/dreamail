# Studio — Google Chat dentro MishMail

Data: 25 novembre 2026
Stato: studio, nessun codice. Niente viene costruito finché il client di posta non è completo e stabile per l'uso quotidiano.
Fonti: documentazione Google letta il 25 novembre 2026 (elenco in fondo, sezione 8). Le pagine per sviluppatori non mostravano una data di ultimo aggiornamento nel testo letto; dove una data c'era è riportata.

## Sintesi (una pagina)

**Risposta.** Sì, una chat nativa è tecnicamente possibile con la Google Chat API e l'accesso come utente, ma non è mai parità con Gmail web e ha due incognite che vanno provate prima di decidere. L'unica strada ufficiale è l'API; la web view incorporata e i protocolli non ufficiali sono sconsigliati.

**I due fatti che decidono.**

1. **Tipo di account.** Google scrive che "per costruire una Chat app o usare la Chat API serve un account Google Workspace" e mette un account Workspace Business o Enterprise tra i prerequisiti. Questo vale di certo per chi configura l'API nel progetto Google Cloud. Per l'utente finale che dà il consenso la documentazione **non dice** se un account personale `@gmail.com` funziona: va provato. Con MishMail il progetto Cloud è dell'utente stesso (client OAuth proprio, vedi `README.md`), quindi un utente con solo account personali potrebbe non riuscire nemmeno ad attivare l'API.
2. **Nessuna consegna in tempo reale a un'app desktop senza infrastruttura.** Gli eventi di Chat arrivano solo su un topic Pub/Sub di Google Cloud. Senza un nostro server restano l'interrogazione periodica (come oggi per la posta) oppure un topic Pub/Sub nel progetto dell'utente. La chat sarebbe "quasi in tempo reale" con qualche secondo o decina di secondi di ritardo, non istantanea.

Un terzo fatto pesa solo se l'app viene distribuita con un client OAuth condiviso: leggere i messaggi richiede uno scope **restricted** (`chat.messages.readonly` o `chat.messages`), cioè verifica OAuth completa e, se i dati passano da un server, valutazione di sicurezza annuale (CASA). Con il client proprio dell'utente si resta nell'eccezione "uso personale", come già accade per `gmail.modify`.

**Raccomandazione.**

1. Quando arriva la barra degli account (DEC-057): **collegamento esterno** a Chat nel browser, per account. Costo: meno di un giorno. Nessun permesso nuovo.
2. Prima di ogni altra decisione: una **prova di 2–3 giorni** con gli account reali del proprietario, che risponde alle due incognite sopra (sezione 6, domande 1–3).
3. Se la prova riesce e la chat serve davvero: **nativa in sola lettura** (opzione C), dietro un interruttore di build `MISHMAIL_CHAT`, con consenso separato per account. La scrittura (opzione D) solo dopo, come passo distinto.
4. **Non** fare la web view incorporata (opzione B).

**Quando non farlo affatto.** Se gli account del proprietario sono personali e la prova mostra che l'API li rifiuta; se l'amministratore Workspace blocca le app di terze parti; se la chat è usata di rado (il collegamento esterno basta); se si vuole distribuire l'app ad altri con un client condiviso senza voler affrontare la verifica restricted.

---

## 1. Che cosa è possibile oggi per un client nativo di terze parti

### 1.1 Google Chat API (REST)

API REST su `chat.googleapis.com`. Risorse documentate: spazi (`spaces`: elenco, creazione, `setup`, `findDirectMessage`, `findGroupChats`, ricerca), membri, messaggi (elenco, creazione, modifica, cancellazione, **ricerca**), allegati (`media.upload`, `media.download`), reazioni, messaggi fissati, emoji personalizzate, eventi dello spazio (`spaceEvents`), stato di lettura per spazio e per thread, impostazioni di notifica per spazio, sezioni, disponibilità dell'utente (`users.availability`). [F1]

### 1.2 Accesso come utente e accesso come app

- **Come utente** (OAuth, quello che serve a MishMail): l'app agisce per l'utente che ha dato il consenso e vede ciò che vede lui. Chat mostra un'attribuzione con il nome dell'app per alcune azioni di scrittura (l'esempio documentato è la creazione di uno spazio; per i messaggi inviati la documentazione letta non lo dice). [F2] [F3]
- **Come app** (service account, scope `chat.bot` o `chat.app.*`): è un bot, non la chat dell'utente. Gli scope `chat.app.*` richiedono l'approvazione una tantum dell'amministratore. Non serve a MishMail. [F2]
- La delega a livello di dominio conta come accesso utente ma richiede un amministratore: non è una strada per un client personale. [F3]

### 1.3 Tipi di account: Workspace o personale

È il punto da verificare con più cura, e la documentazione non lo chiude.

| Chi | Che cosa dice Google | Stato |
|---|---|---|
| Chi configura la Chat API nel progetto Cloud | Prerequisito: "A Business or Enterprise Google Workspace account with access to Google Chat". L'errore "Google Chat API is only available to Google Workspace users" significa che l'account usato per configurare l'API non appartiene a un'organizzazione Workspace. "To build a Chat app or use the Chat API, you must use a Google Workspace account." [F3] [F4] [F5] | Verificato |
| Utente finale che dà il consenso OAuth | Nessuna frase esplicita. Indizi a favore: "Google Chat users can use Chat apps without a Google Workspace account"; la schermata di consenso può avere pubblico "External"; le risorse degli eventi parlano di appartenenza "through their Google Workspace or Google Account". [F3] [F5] [F6] | **Non verificato**: va provato |

Conseguenza per MishMail: oggi ogni utente porta il proprio client OAuth "Desktop app" dal proprio progetto Cloud. Se quel progetto è di un account personale, l'attivazione o la configurazione della Chat API può fallire prima ancora del consenso. Se il progetto è di un account Workspace, resta da provare se con quel client si leggono anche le chat di un account personale aggiunto in MishMail.

### 1.4 Deve esistere una "Chat app" configurata?

- Per le sole chiamate **in lettura** come utente, la pagina di configurazione dice che basta attivare l'API e avere un client OAuth. [F4]
- Per **creare, modificare, cancellare** bisogna anche configurare la Chat API nella console: nome, avatar, descrizione dell'app. Le funzioni interattive (bot) si lasciano spente. [F4]
- La guida all'accesso come utente elenca invece la configurazione tra i prerequisiti in ogni caso. Le due pagine non coincidono: da provare. [F3]
- Non serve pubblicare nulla sul Marketplace.

### 1.5 Scope e classe di sensibilità

Classificazione della pagina di Google sugli scope di Chat. [F2]

| Uso | Scope | Classe |
|---|---|---|
| Elenco di conversazioni e spazi | `chat.spaces.readonly` | Sensitive |
| Membri | `chat.memberships.readonly` | Sensitive |
| **Leggere messaggi e reazioni** | `chat.messages.readonly` | **Restricted** |
| Leggere, inviare, modificare, cancellare messaggi | `chat.messages` | **Restricted** |
| Solo inviare | `chat.messages.create` | Sensitive |
| Reazioni | `chat.messages.reactions` (e `.create`, `.readonly`) | Sensitive |
| Stato di lettura (letto/non letto) | `chat.users.readstate` (e `.readonly`) | Sensitive |
| Creare conversazioni, modificare spazi | `chat.spaces`, `chat.spaces.create` | Sensitive |
| Notifiche per spazio | `chat.users.spacesettings` | Sensitive |
| Emoji personalizzate | `chat.customemojis` (e `.readonly`) | Sensitive |
| Cancellare conversazioni | `chat.delete` | Restricted |

Non esiste una chat leggibile senza uno scope restricted. La Chat API compare nell'elenco di Google delle API con scope restricted, insieme a Gmail e Drive. [F7] Lo scope per `users.availability` non è stato verificato.

### 1.6 Verifica OAuth e CASA

- **Sensitive**: verifica del marchio (dominio di proprietà, pagina iniziale e informativa sulla privacy sullo stesso dominio), giustificazione degli scope, video dimostrativo. Google indica fino a 10 giorni. [F8]
- **Restricted**: tutto il precedente più tipo di applicazione ammesso, regole "Limited Use" e revisioni aggiuntive; Google indica "diverse settimane". [F9]
- **CASA** (valutazione di sicurezza di un valutatore terzo approvato da Google, annuale): richiesta "se si conservano o trasmettono dati restricted su server" e per ogni app che "può accedere ai dati da o attraverso un server di terze parti". [F9] [F10] Un'app che tiene i dati solo sul Mac dell'utente sembrerebbe fuori, ma **nessuna pagina letta lo dichiara come esenzione**: è una nostra lettura, non un'affermazione di Google.
- **Costo CASA**: le pagine di Google lette non indicano tariffe. Una pagina Google su un'altra API parla di 500–4.500 USD secondo la complessità; la comunità riporta 540–675 USD l'anno per il livello più basso. Cifre non ufficiali per Chat: da chiedere a un valutatore. [F11]
- **Eccezioni alla verifica** (quelle che contano qui): uso personale ("sei l'unico utente o gli utenti sono pochi e li conosci di persona"), pubblico limitato sotto i 100 utenti, app in stato Testing, app "Internal" di un'organizzazione Workspace. [F9] [F12] È la situazione di MishMail oggi con `gmail.modify`, che è anch'esso restricted.
- **Stato Testing**: al massimo 100 utenti di prova e le autorizzazioni scadono dopo 7 giorni se si chiede qualunque scope oltre a nome, e-mail e profilo. Vale già per la posta ed è scritto nel `README.md`. [F13]
- **Limite delle app non verificate**: 100 nuovi utenti in tutta la vita del progetto, con la schermata "Google non ha verificato questa app". [F13] [F14]

In breve: con il client proprio dell'utente non c'è nulla da far approvare a Google. Con un client condiviso distribuito ad altri serve la verifica restricted; la CASA dipende dall'esistenza di un server, e MishMail non ne ha.

### 1.7 Approvazione dell'amministratore

- Non serve per l'accesso come utente in sé.
- Un amministratore Workspace può però disattivare le Chat app o ammettere solo quelle in elenco, e può limitare le app di terze parti che accedono ai dati dell'organizzazione ("App access control"). In quel caso il consenso fallisce e solo l'amministratore può sbloccarlo. [F5]
- Per un account di un'organizzazione (azienda, università) questo è il rischio più concreto, e non si scopre senza provare.

### 1.8 Eventi e tempo reale

- **Workspace Events API**: si crea una sottoscrizione; gli eventi arrivano **solo su un topic Pub/Sub** di Google Cloud. Nessun websocket, long-poll o flusso diretto verso un client è documentato. [F6] [F15]
- Con accesso utente si può sottoscrivere un singolo spazio o **tutti gli spazi dell'utente** (`//chat.googleapis.com/spaces/-`). Eventi: messaggio creato/modificato/cancellato, reazione, membri, spazio, stato di lettura. [F6]
- **Scadenza**: fino a 4 ore se l'evento contiene i dati, fino a 7 giorni se contiene solo i riferimenti. Va rinnovata. [F15]
- Nel progetto servono: Pub/Sub attivo, un topic, il ruolo Publisher per `chat-api-push@system.gserviceaccount.com`, una sottoscrizione Pub/Sub (pull per impostazione predefinita). [F16]
- **Alternative senza Pub/Sub**, entrambe a interrogazione:
  - `spaces.spaceEvents.list`: eventi di **uno** spazio, fino a 28 giorni indietro, filtro obbligatorio per tipo di evento. Una chiamata per spazio. [F17]
  - `spaces.messages.search` con `spaces/-`: una sola chiamata su tutti gli spazi, filtrabile per `createTime` e `is_unread()`. Limiti dichiarati: non restituisce i messaggi delle app, quelli privati e quelli degli spazi silenziati; quota più bassa (300 al minuto per progetto). [F18] [F19]

### 1.9 Quote

Per progetto, al minuto: 3.000 letture di messaggi, 3.000 scritture di messaggi, 300 ricerche di messaggi, 3.000 letture di spazi, 60 scritture di spazi, 3.000 letture e 600 scritture di allegati. Per spazio: 15 letture e 1 scrittura al secondo, condivise tra tutte le app. Nessun limite giornaliero entro quelli al minuto. [F19] Per un utente solo sono ampie; l'unico punto stretto è l'interrogazione spazio per spazio con molti spazi.

### 1.10 Strade alternative

| Strada | Che cos'è | Condizioni d'uso e sicurezza |
|---|---|---|
| Web view di `chat.google.com` o `mail.google.com/chat` dentro l'app | Una `WKWebView` con l'interfaccia web di Google | Google "può bloccare gli accessi" da browser "incorporati in un'altra applicazione" e nomina come supportati solo Chrome, Safari, Firefox, Opera, Edge. [F20] La norma OAuth vieta di dirigere una richiesta di autorizzazione a un user-agent incorporato controllato dallo sviluppatore. [F21] L'accesso web non è formalmente una richiesta OAuth, ma il motivo dichiarato da Google è lo stesso (l'app ospite può leggere tasti e cookie). Servirebbero cookie di sessione persistenti su disco: valgono l'intero account Google, non un permesso limitato, e starebbero fuori dal database cifrato. Può smettere di funzionare senza preavviso. |
| XMPP | Il vecchio protocollo di Google Talk | Chiuso: l'accesso dei client di terze parti è terminato il 16 giugno 2022 (fonte: Wikipedia, non Google). [F22] Nessun accesso XMPP all'attuale Google Chat risulta documentato. |
| Protocolli non ufficiali | Librerie che imitano il client web (per esempio il bridge `mautrix-googlechat`) | Non usano un'API pubblica; il metodo di accesso non è stato verificato in questo studio (la documentazione sta su un altro sito). I Termini di servizio di Google vietano di "aggirare i sistemi o le misure di protezione" e prevedono sospensione o chiusura dell'account per violazioni materiali o ripetute. [F23] [F24] Rischio diretto sull'account di posta dell'utente. Da escludere. |

---

## 2. Che cosa offre Gmail web e che cosa copre l'API

Chat in Gmail si accende e si spegne in Impostazioni → "Chat and Meet"; Google dichiara che Chat in Gmail ha le stesse funzioni di Chat. [F25] La struttura esatta del pannello (Home, Mentions, Starred…) non è stata verificata sulle pagine di aiuto: gli indirizzi tentati non rispondevano.

| Funzione in Gmail web | Copertura API (accesso utente) | Note |
|---|---|---|
| Messaggi diretti e di gruppo | **Sì** | `spaces.list` (compaiono dopo il primo messaggio), `findDirectMessage`, `setup` per crearne uno. [F1] [F26] |
| Spazi | **Sì** | Elenco, creazione, membri. [F1] |
| Thread | **Sì** | `thread.name` nei messaggi, stato di lettura per thread. `setup` non crea spazi con risposte a thread. [F1] [F26] |
| Invio, modifica, cancellazione | **Sì** | Solo testo: le schede (card) con accesso utente sono in anteprima per sviluppatori. [F1] |
| Citazione | **Sì, con limiti** | Solo alla creazione; non si può citare una risposta di un altro thread. [F1] |
| Reazioni | **Sì** | Anche con emoji personalizzate. [F1] |
| Menzioni | **Sì** | Annotazioni in lettura, `<users/…>` in scrittura. Con accesso utente il mittente arriva spesso solo come identificativo: il nome va risolto a parte. [F1] |
| File | **In parte** | Caricamento e scaricamento dei file caricati in Chat; i file di Drive no (servirebbe la Drive API, altro scope restricted). I metadati dell'allegato via `attachments.get` risultano solo per accesso come app: da provare. [F1] |
| Ricerca | **Sì** | `messages.search` su uno o tutti gli spazi, con parole chiave, mittente, data, allegati, link, menzioni, non letti. Esclusi messaggi di app e spazi silenziati. Ordinamento per rilevanza in anteprima. [F18] |
| Letto / non letto | **Sì** | Lettura e aggiornamento dello stato per spazio e thread. Nessun conteggio dei non letti documentato: va calcolato. [F1] |
| Presenza e stato | **In parte, non verificato** | Esistono `users.availability.get/patch` e "segna come attivo/assente/non disturbare". Campi, scope e presenza degli altri utenti non verificati. Stato personalizzato: non trovato. [F1] |
| Notifiche | **In parte** | Impostazioni per spazio leggibili e modificabili. Le notifiche vere le produce il client dagli eventi o dall'interrogazione: nessun servizio di push per un'app desktop. [F1] [F6] |
| Huddle e chiamate Meet | **No** | Solo un dato in lettura nel messaggio (riunione o huddle, iniziato/finito/perso). Gli huddle esistono solo per account di lavoro. [F1] [F27] |
| Indicatore "sta scrivendo" | **No** | Nulla nel riferimento. [F1] |
| Messaggi con stella | **No** | Solo i messaggi fissati. [F1] |
| Bozze sincronizzate | **No** | Nulla nel riferimento. [F1] |
| App e bot, comandi slash | **No, in pratica** | I messaggi delle app si leggono; l'interazione (comandi, schede, finestre) non è riproducibile da un client utente. |
| Anteprime dei link, GIF, Smart Compose, funzioni Gemini | **No** | Non coperte o non verificate. |
| Cronologia attiva/spenta | **Lettura** | Il dato è nello spazio; la regola è dell'organizzazione. Con cronologia spenta i messaggi spariscono lato Google: vedi 3.5. |

---

## 3. Come si inserirebbe in MishMail

Letto nel codice al commit `ba8e7aa`.

### 3.1 Account e OAuth

- Lo schema da seguire è quello di Calendar (PR #55, DEC-048): **consenso separato**, chiesto solo su azione esplicita dell'utente, per account; token di aggiornamento proprio nel Keychain (`calendarRefreshToken.<account>` → `chatRefreshToken.<account>`); il token si tiene solo se Google conferma che appartiene a quell'account; il permesso concesso è quello della risposta, non quello chiesto (`CalendarAuthorization`, `CalendarGrant`).
- Gli scope di Chat non entrano mai in `OAuthConfig.scopes` (accesso Gmail).
- In più rispetto a Calendar: l'utente deve attivare la Chat API (e, per scrivere, configurarla) nel proprio progetto Cloud. Va scritto nel `README.md` e gestito come errore leggibile, non come guasto.
- `GoogleHTTP.session` (effimera, senza cache né cookie) va bene così per `chat.googleapis.com`.

### 3.2 Archivio cifrato e migrazioni

- Le migrazioni sono a `v64`. Chat aggiungerebbe tabelle proprie (permesso, spazi, messaggi, stato di lettura), tutte con chiave d'account e cancellazione a cascata, come `CalendarStore`.
- Scelta consigliata per la prima versione: **non conservare i messaggi**, come Calendar non conserva eventi. Solo permesso, elenco degli spazi e segnalibro dell'ultima lettura. È la scelta che rende "cancellato vuol dire sparito" quasi gratuito (3.5).
- La ricerca di Chat userebbe quella di Google (`messages.search`), non l'indice locale.

### 3.3 Sincronizzazione

- La posta usa `history.list` con un `historyId` e un timer (`PollCadence`, più lento con app in secondo piano o risparmio energetico). Chat **non ha un equivalente** unico per account.
- Senza un nostro server, tre possibilità:
  1. **Interrogazione con ricerca globale**: `messages.search` su `spaces/-` con `createTime` dopo l'ultimo controllo. Una chiamata per giro. Limiti: spazi silenziati e messaggi di app esclusi; non segnala modifiche e cancellazioni.
  2. **Interrogazione per spazio**: `spaceEvents.list` sugli spazi aperti o recenti. Completa (anche modifiche, cancellazioni, reazioni), ma una chiamata per spazio.
  3. **Pub/Sub nel progetto dell'utente**: sottoscrizione a tutti gli spazi e pull dal Mac. Più vicino al tempo reale, ma chiede all'utente di configurare Pub/Sub, aggiunge uno scope di Google Cloud e una sottoscrizione da rinnovare. Se Pub/Sub richieda la fatturazione attiva sul progetto non è stato verificato.
- Proposta: 1 per le notifiche, 2 per la conversazione aperta. 3 solo se il ritardo risulta inaccettabile nell'uso reale.

### 3.4 Notifiche (DEC-014, DEC-056)

- Predefinito generico: "New chat message", senza mittente né testo. Mittente e testo solo con l'impostazione per account già esistente, o con una gemella per la chat.
- Identificativi con hash salati, come per la posta. Rimozione delle notifiche con la conversazione e con l'account.
- Come Gmail: nessuna notifica per spazi silenziati e durante "non disturbare" (se la presenza risulta leggibile).

### 3.5 "Cancellato vuol dire sparito" (DEC-019)

- In chat cancellano **anche gli altri**: un messaggio rimosso dal mittente, o svanito perché la cronologia è spenta, deve sparire anche dal Mac. Con l'interrogazione, la cancellazione si scopre solo al giro successivo sullo spazio giusto.
- Per questo conviene non conservare i messaggi: nulla da sovrascrivere, nulla che resti dopo una cancellazione remota. Se in futuro si vuole una cache, ogni messaggio ha bisogno di una scadenza breve e di una riconciliazione all'apertura.
- La rimozione dell'account cancella permesso, token, tabelle e notifiche di Chat (DEC-013).

### 3.6 Log

Nessun testo di messaggio, nome di spazio o indirizzo nei log; `DiagnosticLog.describe` come per Gmail. I messaggi d'errore di Google vanno troncati come in DEC-015.

### 3.7 Interruttore di build

`MISHMAIL_CHAT`, vuoto in `Config/Signing.xcconfig`, espanso in `Info.plist`, letto una volta (`ChatFeatures`, copia di `CalendarFeatures`). Spento: nessuna superficie, nessuna richiesta di scope, nessuna chiamata a `chat.googleapis.com`, con i test che lo controllano. Non è una preferenza.

### 3.8 Barra degli account (DEC-057)

La parte bassa della barra ospita Settings e "altri collegamenti". Chat è per account: il collegamento apre la chat dell'account selezionato; con "tutti gli account" serve una regola (come Gmail: Chat è sempre di un account solo). Un indicatore dei non letti sull'icona è possibile solo con l'opzione nativa.

### 3.9 Non in linea

Senza rete: elenco degli spazi dall'archivio, messaggi non disponibili (se non si conservano), invio rifiutato con avviso. Una coda d'invio come l'Outbox della posta è lavoro dell'opzione D. Che cosa faccia Gmail web con la chat non in linea non è stato verificato.

---

## 4. Opzioni, dalla più piccola alla più grande

Gli ordini di grandezza sono stime da confermare con la prova della sezione 5.

| | A. Collegamento esterno | B. Web view incorporata | C. Nativa in sola lettura | D. Nativa completa |
|---|---|---|---|---|
| Che cosa ottiene l'utente | Un'icona nella barra degli account che apre Chat nel browser, sull'account giusto | L'interfaccia web di Chat dentro una finestra di MishMail: tutte le funzioni, huddle compresi | Elenco di conversazioni e spazi, lettura dei messaggi, non letti, notifiche generiche, ricerca | In più: invio, risposte, modifica, cancellazione, reazioni, allegati, nuove conversazioni, segna come letto |
| Sforzo | Meno di 1 giorno | 1–2 settimane, poi manutenzione imprevedibile | 3–5 settimane | Altri 2–3 mesi |
| Permessi nuovi | Nessuno | Nessuno scope, ma una sessione Google completa dentro l'app | `chat.spaces.readonly`, `chat.memberships.readonly`, `chat.users.readstate.readonly` (sensitive), `chat.messages.readonly` (restricted) | `chat.messages` (restricted), `chat.spaces`, `chat.messages.reactions`, `chat.users.readstate` e altri (sensitive) |
| Che cosa deve approvare Google | Nulla | Nulla formalmente; Google può bloccare l'accesso | Con client proprio: nulla. Con client condiviso: verifica restricted | Come C; in più la Chat API configurata con nome e avatar |
| Che cosa deve fare l'utente | Nulla | Accedere di nuovo a Google dentro l'app | Attivare la Chat API nel proprio progetto; secondo consenso | Come C, più la configurazione della Chat app |
| Rischi | Il parametro per scegliere l'account nell'indirizzo va verificato | Accesso rifiutato da Google; cookie dell'intero account su disco fuori dal database cifrato; contrasto con DEC-019 e con la norma sui browser incorporati; rottura senza preavviso | Le due incognite (tipo di account, blocco dell'amministratore); ritardo dell'interrogazione; nomi dei mittenti da risolvere | Mai parità: niente huddle, "sta scrivendo", stelle, bozze, app; attese di qualità da client di chat; coda d'invio e conflitti |

### Raccomandazione

**A quando arriva la barra degli account; poi la prova; C solo se la prova riesce e l'uso lo giustifica; D come decisione separata dopo qualche settimana di C. Mai B.**

Motivi:

- A costa quasi nulla, non chiede permessi e copre da subito il 100% delle funzioni, nel posto dove Google le mantiene.
- C è il più piccolo passo nativo che dà qualcosa che il browser non dà: non letti e notifiche accanto alla posta, con le regole di riservatezza di MishMail. Usa già lo scope restricted, quindi rivela tutti gli ostacoli (account, amministratore, progetto Cloud) prima di investire nei mesi di D.
- D da solo non raggiunge Gmail web e ha il costo più alto: va scelto sapendo quanto la chat viene usata davvero.
- B scambia una settimana di lavoro con il rischio più grave dello studio: credenziali dell'intero account in una web view che Google dichiara di poter bloccare.

### Quando raccomanderei di non farlo

- Gli account in uso sono personali e la prova mostra che l'API (o la sua attivazione) li rifiuta.
- L'amministratore dell'organizzazione blocca le app di terze parti su Chat e non intende sbloccarle.
- La chat è usata poche volte al giorno: A basta.
- Si decide di distribuire MishMail con un client OAuth condiviso: allora la chat porta la verifica restricted (e forse la CASA) in aggiunta a quella per la posta, e conviene tenerla fuori dalla prima versione distribuita.
- Servono soprattutto huddle e chiamate: l'API non li offre.

---

## 5. Che cosa fare adesso

Poco, e a costo quasi zero.

**Da fare nel lavoro già previsto**

1. **Barra degli account (DEC-057)**: disegnare la parte bassa come un elenco di voci, non come un solo pulsante Settings; ogni voce può essere "per account". Così Chat e Calendar si aggiungono senza rifare la barra.
2. **Permessi per servizio**: quando si tocca di nuovo `CalendarAuthorization`, tenere distinti il meccanismo (consenso separato, verifica dell'account, token nel Keychain con prefisso del servizio) e ciò che è proprio di Calendar. Non generalizzare ora: basta non intrecciarli di più.
3. **Rimozione dell'account**: mantenere un unico punto in cui un servizio registra ciò che va cancellato (tabelle, token, notifiche), come già fa Calendar.
4. **Notifiche**: tenere il tipo di notifica (posta, promemoria) come dato, non come ramo di codice sparso; una terza categoria si aggiunge allora senza toccare le regole di DEC-014.
5. **La prova di 2–3 giorni**, quando il proprietario lo decide: uno script fuori dall'app, con il client OAuth del proprietario, che tenta attivazione dell'API, consenso con `chat.spaces.readonly` e `chat.messages.readonly`, `spaces.list`, `messages.list`, `messages.search` su `spaces/-`, su un account Workspace e su uno personale. Risponde alle domande 1–3.

**Da non fare**

- Non aggiungere scope di Chat a `OAuthConfig.scopes` né a nessun consenso esistente.
- Non introdurre una `WKWebView` con archivio dati persistente o con accesso a Google: `WebViewPool` usa archivi non persistenti e così deve restare.
- Non costruire ora astrazioni "multi-servizio" o un motore di sincronizzazione generico: Chat non ha un `historyId` e il modello sarebbe sbagliato.
- Non assumere nel modello dati che "conversazione" voglia dire solo thread di posta in punti nuovi dell'interfaccia (barra laterale, badge): non serve cambiare nulla oggi, solo non irrigidire.
- Non usare librerie o protocolli non ufficiali, nemmeno per una prova.

---

## 6. Domande aperte per il proprietario

1. Gli account con cui useresti la chat sono Workspace (azienda, università) o personali `@gmail.com`? E il progetto Google Cloud del tuo client OAuth a quale account appartiene?
2. Se uno è di un'organizzazione: l'amministratore permette le app di terze parti su Chat, o sei in grado di chiederlo?
3. Autorizzi la prova di 2–3 giorni con i tuoi account reali (sezione 5, punto 5)? Legge solo elenchi e messaggi, non scrive nulla.
4. Quanto usi la chat in Gmail, e per che cosa: leggere e rispondere a messaggi diretti, seguire spazi, huddle? Decide tra A, C e D.
5. Un ritardo di alcune decine di secondi sulle notifiche di chat è accettabile? Se no, serve Pub/Sub nel tuo progetto Cloud (più configurazione).
6. Va bene che la prima versione nativa non conservi i messaggi sul Mac (niente chat non in linea), per rispettare "cancellato vuol dire sparito" senza eccezioni?
7. MishMail verrà distribuita ad altri con un client OAuth condiviso? Se sì, la chat porta con sé la verifica restricted di Google.
8. Per le notifiche di chat vale la stessa impostazione per account della posta ("Show sender and subject"), o ne vuoi una separata?
9. Con "tutti gli account" selezionato, il collegamento Chat che cosa apre: l'ultimo account usato, o chiede quale?

---

## 7. Che cosa non è stato verificato

- Se un account personale può dare il consenso agli scope di Chat e leggere le proprie chat (1.3).
- Se la configurazione della "Chat app" è obbligatoria anche per la sola lettura (1.4).
- Se i messaggi inviati con accesso utente portano un'etichetta con il nome dell'app (1.2).
- `users.availability`: campi, scope, visibilità della presenza altrui (sezione 2).
- Campi di `SpaceReadState` e modo di calcolare i non letti; metadati degli allegati con accesso utente; limiti di `media.upload`.
- Costo della CASA per Chat e se un'app solo locale ne sia esente (1.6).
- Se Pub/Sub nel progetto dell'utente richieda la fatturazione attiva (3.3).
- Il parametro dell'indirizzo che apre Chat sull'account giusto nel browser (opzione A).
- Il metodo di accesso di `mautrix-googlechat` e la struttura esatta del pannello Chat in Gmail web.
- Le date di ultimo aggiornamento delle pagine per sviluppatori, non presenti nel testo letto.

---

## 8. Fonti

Tutte lette il 25 novembre 2026.

- [F1] Riferimento REST della Chat API — https://developers.google.com/workspace/chat/api/reference/rest (e le pagine dei metodi `spaces.messages/list`, `spaces/list`, `spaces/search`, `users.spaces/getSpaceReadState`, `media/download`, `spaces.messages.attachments/get`)
- [F2] Autenticazione e autorizzazione, tabella degli scope — https://developers.google.com/workspace/chat/authenticate-authorize
- [F3] Accesso come utente di Chat — https://developers.google.com/workspace/chat/authenticate-authorize-chat-user
- [F4] Configurare la Chat API — https://developers.google.com/workspace/chat/configure-chat-api
- [F5] Risoluzione dei problemi delle Chat app — https://developers.google.com/workspace/chat/troubleshoot-chat-apps
- [F6] Eventi di Chat con la Workspace Events API — https://developers.google.com/workspace/events/guides/events-chat
- [F7] Elenco degli scope restricted — https://support.google.com/cloud/answer/13464325
- [F8] Verifica degli scope sensitive — https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification
- [F9] Verifica degli scope restricted — https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification
- [F10] Valutazione di sicurezza (CASA) — https://support.google.com/cloud/answer/13465431
- [F11] Costi CASA, fonti non ufficiali per Chat — https://developers.google.com/health/app-verification ; https://groups.google.com/g/google-apps-script-community/c/-A00Ngimg1A
- [F12] Quando la verifica non serve — https://support.google.com/cloud/answer/13464323
- [F13] Pubblico dell'app, stato Testing, scadenza a 7 giorni — https://support.google.com/cloud/answer/15549945
- [F14] App non verificate — https://support.google.com/cloud/answer/7454865
- [F15] Workspace Events API, panoramica e scadenze — https://developers.google.com/workspace/events
- [F16] Creare una sottoscrizione — https://developers.google.com/workspace/events/guides/create-subscription
- [F17] `spaces.spaceEvents.list` — https://developers.google.com/workspace/chat/api/reference/rest/v1/spaces.spaceEvents/list
- [F18] `spaces.messages.search` — https://developers.google.com/workspace/chat/api/reference/rest/v1/spaces.messages/search
- [F19] Limiti d'uso — https://developers.google.com/workspace/chat/limits
- [F20] Accedere con un browser supportato — https://support.google.com/accounts/answer/7675428
- [F21] Norme OAuth 2.0 (ultima modifica: 5 agosto 2026) — https://developers.google.com/identity/protocols/oauth2/policies ; annuncio del 29 giugno 2021 sulle web view incorporate — https://developers.googleblog.com/en/upcoming-security-changes-to-googles-oauth-20-authorization-endpoint-in-embedded-webviews/
- [F22] Google Talk, chiusura dell'accesso XMPP (Wikipedia) — https://en.wikipedia.org/wiki/Google_Talk
- [F23] Termini di servizio di Google (in vigore dal 30 luglio 2026) — https://policies.google.com/terms
- [F24] `mautrix-googlechat` — https://github.com/mautrix/googlechat
- [F25] Usare Google Chat in Gmail — https://support.google.com/chat/answer/9341104
- [F26] `spaces.setup` — https://developers.google.com/workspace/chat/api/reference/rest/v1/spaces/setup
- [F27] Huddle in Google Chat — https://support.google.com/chat/answer/14932552
- Norma sui dati utente dei servizi API di Google, "Limited Use" (ultimo aggiornamento: 15 febbraio 2024) — https://developers.google.com/terms/api-services-user-data-policy
- Funzioni di Chat per tipo di account — https://support.google.com/chat/answer/9291345
