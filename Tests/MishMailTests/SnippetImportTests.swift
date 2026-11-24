import XCTest

final class SnippetImportTests: XCTestCase {

    func testDecode() throws {
        let json = """
        [{"name": "Zoom Link", "body": "Here's my zoom link: {zoom_link}"},
         {"name": "intro find time", "body": "Thanks {bcc_first_name}!", "movesToBcc": true},
         {"name": "work only", "body": "Hi", "accountIds": ["a@x.com"]}]
        """
        let items = try SnippetImport.decode(Data(json.utf8))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].name, "Zoom Link")
        XCTAssertNil(items[0].movesToBcc)
        XCTAssertEqual(items[1].movesToBcc, true)
        XCTAssertEqual(items[2].accountIds, ["a@x.com"])
    }

    func testPlanSkipsExistingNamesCaseInsensitively() {
        let items = [
            SnippetImport.Item(name: "Follow Up", body: "x", movesToBcc: nil),
            SnippetImport.Item(name: "New One", body: "y", movesToBcc: nil),
        ]
        let planned = SnippetImport.plan(items, existingNames: ["follow up"])
        XCTAssertEqual(planned.map(\.name), ["New One"])
    }

    func testPlanSkipsBlanksAndInFileDuplicates() {
        let items = [
            SnippetImport.Item(name: "  ", body: "x", movesToBcc: nil),
            SnippetImport.Item(name: "A", body: "  \n ", movesToBcc: nil),
            SnippetImport.Item(name: "B", body: "ok", movesToBcc: nil),
            SnippetImport.Item(name: "b", body: "dupe", movesToBcc: nil),
        ]
        XCTAssertEqual(SnippetImport.plan(items, existingNames: []).map(\.name), ["B"])
    }

    func testBadJSONThrows() {
        XCTAssertThrowsError(try SnippetImport.decode(Data("not json".utf8)))
    }

    func testDefaultsAreSeedableAndSelfConsistent() {
        let items = SnippetDefaults.items
        // Minimal public set: intro (Bcc demo) + cal — no personal URLs/names.
        XCTAssertEqual(items.map(\.name), ["intro find time", "cal"])
        for item in items {
            XCTAssertFalse(item.name.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(item.body.contains("://"),
                           "defaults must not ship personal calendar links")
            XCTAssertFalse(item.body.lowercased().contains("rboger"),
                           "defaults must not ship identifying names")
        }
        XCTAssertEqual(items.filter { $0.movesToBcc == true }.map(\.name), ["intro find time"])
        XCTAssertEqual(SnippetImport.plan(items, existingNames: []).count, items.count)
        XCTAssertEqual(SnippetImport.plan(items, existingNames: items.map(\.name)).count, 0)
    }

    /// Only MishMail's own keys are read; other exports' key names are not.
    func testAlternateKeysAreUnrecognized() {
        let json = """
        [{"shortcut": "intro", "content": "Hi {first_name}"},
         {"title": "cal", "text": "Link: {date}"}]
        """
        XCTAssertThrowsError(try SnippetImport.decode(Data(json.utf8))) { error in
            XCTAssertTrue(error is SnippetImport.ImportError)
        }
    }

    /// Only an array or a single snippet object is read; an object wrapping
    /// a list under some key is not a MishMail format.
    func testWrappedJSONIsUnrecognized() {
        let json = #"{"snippets": [{"name": "intro", "body": "Hi"}]}"#
        XCTAssertThrowsError(try SnippetImport.decode(Data(json.utf8))) { error in
            XCTAssertTrue(error is SnippetImport.ImportError)
        }
    }

    func testSingleObjectJSONImports() throws {
        let json = #"{"name": "thanks", "body": "Thanks {{first_name}}!"}"#
        let items = try SnippetImport.decode(Data(json.utf8))
        XCTAssertEqual(items.map(\.name), ["thanks"])
        XCTAssertEqual(items[0].body, "Thanks {{first_name}}!")
    }

    func testCSVImportReadsNameBodyAndBccColumns() throws {
        let csv = """
        Name,Body,movesToBcc
        intro,"Hi {first_name}",true
        cal,See you {date},false
        """
        let items = try SnippetImport.decode(Data(csv.utf8))
        XCTAssertEqual(items.map(\.name), ["intro", "cal"])
        XCTAssertEqual(items[0].body, "Hi {first_name}")
        XCTAssertEqual(items[0].movesToBcc, true)
        XCTAssertEqual(items[1].movesToBcc, false)
    }

    /// A CSV without `name` and `body` headers is not guessed column by
    /// column.
    func testCSVWithOtherHeadersIsUnrecognized() {
        let csv = """
        shortcut,content,bcc
        intro,"Hi {first_name}",true
        """
        XCTAssertThrowsError(try SnippetImport.decode(Data(csv.utf8))) { error in
            XCTAssertTrue(error is SnippetImport.ImportError)
        }
    }

    func testCSVQuotedNewlinesStayInBody() throws {
        let csv = """
        name,body
        intro,"Hello,
        there"
        """
        let items = try SnippetImport.decode(Data(csv.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].body, "Hello,\nthere")
    }

    func testEmptyJSONArrayIsValid() throws {
        XCTAssertEqual(try SnippetImport.decode(Data("[]".utf8)), [])
    }

    func testGarbageIsUnrecognized() {
        XCTAssertThrowsError(try SnippetImport.decode(Data("not json or csv".utf8))) { error in
            XCTAssertTrue(error is SnippetImport.ImportError)
        }
    }

    /// Bodies are stored as written: placeholders, unknown tokens and code
    /// braces all survive import for compose to expand (or leave) later.
    func testBodiesImportVerbatim() throws {
        let body = "Hi {{First Name}} / {{first_name}} / {date} — struct X { let a = 1 }"
        let json = try JSONSerialization.data(withJSONObject: [["name": "raw", "body": body]])
        XCTAssertEqual(try SnippetImport.decode(json).map(\.body), [body])
        let csv = "name,body\nraw,\"\(body)\"\n"
        XCTAssertEqual(try SnippetImport.decode(Data(csv.utf8)).map(\.body), [body])
    }
}
