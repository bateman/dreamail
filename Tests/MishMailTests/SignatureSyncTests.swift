import XCTest
import GRDB

/// Signatures follow Gmail by themselves (v67): new, changed on Gmail,
/// edited here, deleted on Gmail, defaults kept; the refresh throttle; the
/// compose signature menu. No network: Gmail's answer is given as data.
final class SignatureSyncTests: XCTestCase {
    private let a = "a@example.com"
    private let alias = "alias@example.com"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.a, displayName: self.a, historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
        }
        return q
    }

    @discardableResult
    private func apply(_ q: DatabaseQueue, _ gmail: [String: GmailSignature])
        throws -> SignatureStore.GmailOutcome {
        try q.write { try SignatureStore.applyGmail($0, accountId: self.a, gmail: gmail) }
    }

    private func book(_ q: DatabaseQueue) throws -> SignatureBook {
        try q.read { try SignatureStore.load($0) }
    }

    // MARK: - Migration

    func testMigrationAddsTheGmailLinkAndTable() throws {
        let q = try makeDB()
        try q.read { db in
            XCTAssertTrue(try AppDatabase.migrator.appliedIdentifiers(db).contains("v67"))
            let columns = try db.columns(in: "signature").map(\.name)
            XCTAssertTrue(columns.contains("gmailAddress"))
            XCTAssertTrue(columns.contains("editedHere"))
            XCTAssertTrue(try db.tableExists("signatureGmail"))
        }
    }

    // MARK: - Rules

    func testNewGmailSignatureIsAddedNamedAfterTheAddressAndBecomesTheDefault() throws {
        let q = try makeDB()
        let outcome = try apply(q, [a: .text("Ann\n**Uni**")])
        XCTAssertEqual(outcome.added, 1)
        let b = try book(q)
        let s = try XCTUnwrap(b.signatures(for: a).first)
        XCTAssertEqual(s.name, a)
        XCTAssertEqual(s.body, "Ann\n**Uni**")
        XCTAssertEqual(s.gmailAddress, a)
        XCTAssertEqual(b.gmailState(of: s), .synced)
        XCTAssertEqual(b.defaultSignature(use: .newMessage, accountId: a, email: a)?.id, s.id)
        XCTAssertEqual(b.defaultSignature(use: .reply, accountId: a, email: a)?.id, s.id)
        // The same answer again changes nothing.
        XCTAssertEqual(try apply(q, [a: .text("Ann\n**Uni**")]), .init())
        XCTAssertEqual(try book(q).signatures(for: a).count, 1)
    }

    func testAnAddressWithADefaultKeepsIt() throws {
        let q = try makeDB()
        try q.write { db in
            try SignatureStore.setDefault(db, accountId: self.a, email: self.alias,
                                          use: .newMessage, choice: .none)
        }
        try apply(q, [alias: .text("Alias sig")])
        let b = try book(q)
        XCTAssertEqual(b.signatures(for: a).map(\.name), [alias])
        XCTAssertNil(b.defaultSignature(use: .newMessage, accountId: a, email: alias))
    }

    func testAChangeOnGmailUpdatesAnUneditedCopyButNotItsDefaults() throws {
        let q = try makeDB()
        try apply(q, [a: .text("Old")])
        let id = try XCTUnwrap(try book(q).signatures(for: a).first?.id)
        try q.write { db in
            try SignatureStore.setDefault(db, accountId: self.a, email: self.a,
                                          use: .reply, choice: .none)
        }
        XCTAssertEqual(try apply(q, [a: .text("New")]).updated, 1)
        let b = try book(q)
        XCTAssertEqual(b.signature(id: id)?.body, "New")
        XCTAssertNil(b.defaultSignature(use: .reply, accountId: a, email: a))
        XCTAssertEqual(b.defaultSignature(use: .newMessage, accountId: a, email: a)?.id, id)
    }

    func testACopyEditedHereIsNotOverwrittenAndUseGmailsRestoresIt() throws {
        let q = try makeDB()
        try apply(q, [a: .text("Gmail v1")])
        let id = try XCTUnwrap(try book(q).signatures(for: a).first?.id)
        try q.write { try SignatureStore.update($0, id: id, name: "Mine", body: "Edited") }
        XCTAssertEqual(try book(q).signature(id: id)?.editedHere, true)

        try apply(q, [a: .text("Gmail v2")])
        var b = try book(q)
        let s = try XCTUnwrap(b.signature(id: id))
        XCTAssertEqual(s.body, "Edited")
        XCTAssertEqual(s.name, "Mine")
        XCTAssertEqual(b.gmailState(of: s), .differs(gmailBody: "Gmail v2"))

        try q.write { try SignatureStore.useGmailVersion($0, id: id) }
        b = try book(q)
        XCTAssertEqual(b.signature(id: id)?.body, "Gmail v2")
        XCTAssertEqual(b.signature(id: id)?.editedHere, false)
        // It follows Gmail again.
        try apply(q, [a: .text("Gmail v3")])
        XCTAssertEqual(try book(q).signature(id: id)?.body, "Gmail v3")
    }

    func testARenameIsNotAnEdit() throws {
        let q = try makeDB()
        try apply(q, [a: .text("Gmail v1")])
        let id = try XCTUnwrap(try book(q).signatures(for: a).first?.id)
        try q.write { try SignatureStore.update($0, id: id, name: "Work", body: "Gmail v1") }
        try apply(q, [a: .text("Gmail v2")])
        let s = try XCTUnwrap(try book(q).signature(id: id))
        XCTAssertEqual(s.name, "Work")
        XCTAssertEqual(s.body, "Gmail v2")
    }

    func testDeletedOnGmailAnUnusedCopyGoesADefaultStaysMarked() throws {
        let q = try makeDB()
        try apply(q, [a: .text("Primary"), alias: .text("Alias")])
        let b0 = try book(q)
        let aliasId = try XCTUnwrap(b0.signatures(for: a).first { $0.gmailAddress == alias }?.id)
        // The alias copy is used by no default.
        try q.write { db in
            try SignatureStore.setDefault(db, accountId: self.a, email: self.alias,
                                          use: .newMessage, choice: .followPrimary)
            try SignatureStore.setDefault(db, accountId: self.a, email: self.alias,
                                          use: .reply, choice: .followPrimary)
        }
        let outcome = try apply(q, [:])
        XCTAssertEqual(outcome.removed, 1)
        let b = try book(q)
        XCTAssertNil(b.signature(id: aliasId))
        let primary = try XCTUnwrap(b.signatures(for: a).first)
        XCTAssertEqual(b.gmailState(of: primary), .gone)
        XCTAssertEqual(b.defaultSignature(use: .newMessage, accountId: a, email: a)?.id, primary.id)
        // Back on Gmail: the kept copy follows it again.
        try apply(q, [a: .text("Primary 2")])
        let back = try XCTUnwrap(try book(q).signature(id: primary.id))
        XCTAssertEqual(back.body, "Primary 2")
        XCTAssertEqual(try book(q).gmailState(of: back), .synced)
    }

    func testAnEditedCopyStaysWhenDeletedOnGmail() throws {
        let q = try makeDB()
        try apply(q, [alias: .text("Alias")])
        let id = try XCTUnwrap(try book(q).signatures(for: a).first?.id)
        try q.write { db in
            try SignatureStore.update(db, id: id, name: "Alias", body: "Mine")
            try SignatureStore.setDefault(db, accountId: self.a, email: self.alias,
                                          use: .newMessage, choice: .none)
            try SignatureStore.setDefault(db, accountId: self.a, email: self.alias,
                                          use: .reply, choice: .none)
        }
        try apply(q, [:])
        let s = try XCTUnwrap(try book(q).signature(id: id))
        XCTAssertEqual(try book(q).gmailState(of: s), .gone)
    }

    func testACopyDeletedHereIsNotAddedAgainUntilGmailChangesIt() throws {
        let q = try makeDB()
        try apply(q, [a: .text("Sig")])
        let id = try XCTUnwrap(try book(q).signatures(for: a).first?.id)
        try q.write { try SignatureStore.delete($0, id: id) }
        XCTAssertEqual(try apply(q, [a: .text("Sig")]).added, 0)
        XCTAssertTrue(try book(q).signatures(for: a).isEmpty)
        XCTAssertEqual(try apply(q, [a: .text("Sig, new")]).added, 1)
        // Not the first time this address is seen: the user's "none" stays.
        XCTAssertNil(try book(q).defaultSignature(use: .newMessage, accountId: a, email: a))
    }

    func testAManualImportWithTheSameTextBecomesTheCopy() throws {
        let q = try makeDB()
        try q.write { db in
            _ = try SignatureStore.insert(db, accountId: self.a, name: "Gmail – \(self.a)", body: "Ann")
        }
        XCTAssertEqual(try apply(q, [a: .text("Ann")]).added, 0)
        let s = try XCTUnwrap(try book(q).signatures(for: a).first)
        XCTAssertEqual(try book(q).signatures(for: a).count, 1)
        XCTAssertEqual(s.gmailAddress, a)
    }

    func testAnUnusableSignatureChangesNothing() throws {
        let q = try makeDB()
        try apply(q, [a: .text("Ann")])
        let before = try book(q)
        try apply(q, [a: .unusable(reason: "too large")])
        XCTAssertEqual(try book(q), before)
        XCTAssertEqual(GmailSignature.from(html: String(repeating: "x", count: 60_000)),
                       .unusable(reason: "too large"))
        XCTAssertEqual(GmailSignature.from(html: "<img src=\"https://example.com/a.png\">"),
                       .unusable(reason: "no text MishMail can keep"))
        XCTAssertNil(GmailSignature.from(html: "  "))
        XCTAssertNil(GmailSignature.from(html: nil))
    }

    func testRemoteImagesAreDroppedAndCounted() throws {
        let html = "<div>Ann<img src=\"https://tracker.example.com/p.gif\"></div>"
        guard case .text(let body, let rich, let images, _)? = GmailSignature.from(html: html) else {
            return XCTFail("expected a signature")
        }
        XCTAssertEqual(body, "Ann")
        XCTAssertEqual(images, 1)
        XCTAssertEqual(rich, "<div>Ann</div>")
        let q = try makeDB()
        try apply(q, [a: GmailSignature.from(html: html)!])
        let record = try XCTUnwrap(try book(q).gmailRecord(accountId: a, email: a))
        XCTAssertFalse(record.body.contains("tracker"))
        XCTAssertEqual(record.droppedImages, 1)
    }

    func testSyncStateGoesWithTheAccount() throws {
        let q = try makeDB()
        try apply(q, [a: .text("Ann")])
        try q.write { db in try SignatureStore.forget(db, accountId: self.a) }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM signatureGmail"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM signature"), 0)
        }
        try apply(q, [a: .text("Ann")])
        try q.write { db in _ = try Account.deleteOne(db, key: self.a) }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM signatureGmail"), 0)
        }
    }

    // MARK: - Throttle

    func testRefreshIsThrottledToOncePerIntervalUnlessForced() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(SignatureSyncPolicy.isDue(nil, force: false, now: t0))
        let done = SignatureSyncState(status: .done, lastAttempt: t0, lastSuccess: t0)
        XCTAssertFalse(SignatureSyncPolicy.isDue(done, force: false, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(SignatureSyncPolicy.isDue(done, force: true, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(SignatureSyncPolicy.isDue(
            done, force: false, now: t0.addingTimeInterval(SignatureSyncPolicy.interval)))
        // A failed refresh waits too: no hammering while offline.
        let offline = SignatureSyncState(status: .offline, lastAttempt: t0)
        XCTAssertFalse(SignatureSyncPolicy.isDue(offline, force: false, now: t0.addingTimeInterval(60)))
        // One at a time, even when forced.
        let running = SignatureSyncState(status: .refreshing, lastAttempt: t0)
        XCTAssertFalse(SignatureSyncPolicy.isDue(running, force: true, now: t0.addingTimeInterval(600)))
        // A clock set back does not block it.
        XCTAssertTrue(SignatureSyncPolicy.isDue(done, force: false, now: t0.addingTimeInterval(-60)))
        XCTAssertEqual(SignatureSyncPolicy.interval, 300)
    }

    // MARK: - Compose menu

    private func sig(_ id: Int64, _ name: String, _ body: String) -> SignatureRecord {
        SignatureRecord(id: id, accountId: a, name: name, body: body,
                        createdAt: Date(timeIntervalSince1970: 0))
    }

    func testMenuRowsAreManageThenNoSignatureThenEachSignature() {
        let rows = ComposeSignatureMenu.rows(signatures: [sig(1, "Formal", "F"), sig(2, "Simple", "S")],
                                             selection: .signature(2))
        XCTAssertEqual(rows, [.manage, .divider, .none(checked: false),
                              .signature(id: 1, name: "Formal", checked: false),
                              .signature(id: 2, name: "Simple", checked: true)])
        XCTAssertEqual(ComposeSignatureMenu.rows(signatures: [], selection: .none),
                       [.manage, .divider, .none(checked: true)])
        // A signature the user typed or edited: nothing checked.
        XCTAssertFalse(ComposeSignatureMenu.rows(signatures: [sig(1, "Formal", "F")],
                                                 selection: .custom).contains {
            if case .none(true) = $0 { return true }
            if case .signature(_, _, true) = $0 { return true }
            return false
        })
    }

    func testTheCheckMarkFollowsChoicesAndKeepsTypedText() {
        let formal = sig(1, "Formal", "Ann Example\nProfessor")
        let simple = sig(2, "Simple", "Ann")
        var state = ComposeSignatureState()
        var head = state.choose(formal, in: "Hello", known: [formal.body, simple.body])
        XCTAssertEqual(state.selection(in: head), .signature(1))
        head = state.choose(simple, in: "Hello there" + head.dropFirst("Hello".count),
                            known: [formal.body, simple.body])
        XCTAssertEqual(head, "Hello there\n\n-- \nAnn")
        XCTAssertEqual(ComposeSignatureMenu.rows(signatures: [formal, simple],
                                                 selection: state.selection(in: head)).last,
                       .signature(id: 2, name: "Simple", checked: true))
        head = state.choose(nil, in: head, known: [formal.body, simple.body])
        XCTAssertEqual(head, "Hello there")
        XCTAssertEqual(state.selection(in: head), .none)
    }
}

/// v67 (this branch) registers last; v66 belongs to another open branch. A
/// database that already ran every other migration must still get v67.
final class SignatureSyncMigrationOrderTests: XCTestCase {
    func testV67RunsOnADatabaseThatAlreadyHasTheOthers() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try db.drop(table: "signatureGmail")
            try db.alter(table: "signature") { t in
                t.drop(column: "gmailAddress")
                t.drop(column: "editedHere")
            }
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v67'")
        }
        try q.read { db in
            let applied = try AppDatabase.migrator.appliedIdentifiers(db)
            XCTAssertTrue(applied.contains("v63"))
            XCTAssertTrue(applied.contains("v65"))
            XCTAssertFalse(applied.contains("v67"))
        }
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            XCTAssertTrue(try AppDatabase.migrator.appliedIdentifiers(db).contains("v67"))
            XCTAssertTrue(try db.tableExists("signatureGmail"))
            XCTAssertTrue(try db.columns(in: "signature").contains { $0.name == "gmailAddress" })
            XCTAssertTrue(try AppDatabase.migrator.hasCompletedMigrations(db))
        }
    }
}
