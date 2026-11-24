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

## Ondata 2 — in parallelo

| Step | Contenuto | Finding | File principali |
|---|---|---|---|
| 2A | AI e server MCP spenti dietro un interruttore | F-05, F-06, F-12 e parte AI di F-04 | `UI/SettingsView.swift`, `App/MailStore+AI.swift`, `MCP/` |
| 2B | Cancellazione completa dell'account e anteprime notifiche | F-04, F-11 | `App/MailStore+Accounts.swift`, `Support/Notifier.swift` |
| 2C | Pin di GRDB per revisione, `Package.resolved` o verifica del checksum del binario in CI | F-10 (parte restante) | `project.yml`, `.github/` |
| 2D | Log residui fuori da `DiagnosticLog`: errori del database con testo SQL e percorsi, eccezione di layout del testo, identificativo di thread nelle metriche | F-03 (parte restante) | `Store/Database.swift`, `Support/SafeTextLayout.m`, `UI/ThreadDetailView.swift` |

2C e 2D sono emersi dalle review dell'ondata 1.

F-08 (limiti sull'estrazione degli update) è rimandato alla distribuzione: con l'updater spento non è raggiungibile.

Altri seguiti annotati, non ancora pianificati:

- `make release` e il README usano lo xcodegen presente sulla macchina del maintainer, non quello fissato in CI.
- Dopo la conversione, il vecchio file in chiaro viene scollegato ma non sovrascritto; il percorso di reset conserva `mail.sqlite.unreadable`.
- Le voci già scritte nel log di sistema da versioni precedenti non si possono eliminare.

## Cancello — prova su Mac del proprietario

☐ Build locale, test e uso della demo.
☐ Verifiche che la CI non copre, emerse dall'ondata 1: pannello Aggiornamenti disabilitato e nessuna richiesta verso GitHub; nuovo accesso a Google con il listener limitato (Safari e Chrome); avvio con un vecchio database in chiaro e una seconda copia aperta (striscia di sola lettura, schermata "Finish encrypting your mail"); eliminazione del vecchio file di log all'avvio.
☐ Solo dopo, collegamento di un account Gmail reale.

## Ondata 3 — parità Gmail

- Creazione e modifica dei filtri server-side.
- Gestione dei colori delle label.
- Verifica ICS/RSVP su inviti reali e gap analysis rispetto a Postie.
- Snooze: richiede prima una scelta di progetto (allineamento con Gmail Web e mobile).

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
| 2A–2D | — | — | Da avviare |
