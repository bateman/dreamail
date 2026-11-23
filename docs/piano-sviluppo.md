# Piano di sviluppo a step

Ultimo aggiornamento: 23 novembre 2026
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

## Ondata 2 — in parallelo, dopo il merge dell'ondata 1

| Step | Contenuto | Finding | File principali |
|---|---|---|---|
| 2A | AI e server MCP spenti dietro un interruttore | F-05, F-06, F-12 e parte AI di F-04 | `UI/SettingsView.swift`, `App/MailStore+AI.swift`, `MCP/` |
| 2B | Cancellazione completa dell'account e anteprime notifiche | F-04, F-11 | `App/MailStore+Accounts.swift`, `Support/Notifier.swift` |

2A viene dopo 1A perché entrambi toccano `SettingsView.swift` e `MishMailApp.swift`.

F-08 (limiti sull'estrazione degli update) è rimandato alla distribuzione: con l'updater spento non è raggiungibile.

## Cancello — prova su Mac del proprietario

☐ Build locale, test e uso della demo.
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
| 0 | `docs/registro-decisioni-v0.7` | — | Completato |
| 1A | `security/fork-identity-updater-off` | — | Avviato |
| 1B | `security/database-fail-closed` | — | Avviato |
| 1C | `security/diagnostic-log-privacy` | — | Avviato |
| 1D | `security/oauth-listener-limits` | — | Avviato |
| 1E | `ci/least-privilege-pinning` | — | Avviato |
| 1F | `tests/caret-scroll-deterministic` | — | Avviato |
