import JSONSchema
import XCTest

@testable import JSONSchemaForm

/// Mock search client with scripted pages (by request index) and request
/// recording. The first request can be gated so tests can interleave
/// overlapping loads deterministically.
@MainActor
private final class MockSearchClient: ForeignKeySearchClient {
    struct Request: Equatable {
        let endpoint: String
        let query: String?
        let cursor: String?
    }

    var pages: [ForeignKeyPage] = []
    var error: Error?
    var requests: [Request] = []

    /// When true, the first search suspends until `releaseGate()` is called.
    var gateFirstSearch = false
    private var gateContinuation: CheckedContinuation<Void, Never>?

    func releaseGate() {
        gateContinuation?.resume()
        gateContinuation = nil
    }

    func search(endpoint: String, query: String?, cursor: String?) async throws -> ForeignKeyPage {
        let index = requests.count
        requests.append(Request(endpoint: endpoint, query: query, cursor: cursor))
        if index == 0, gateFirstSearch {
            await withCheckedContinuation { gateContinuation = $0 }
        }
        if let error { throw error }
        guard index < pages.count else { return ForeignKeyPage(items: [], nextCursor: nil) }
        return pages[index]
    }

    var resolveResult: ForeignKeyItem?
    func resolve(endpoint: String, id: String) async throws -> ForeignKeyItem? {
        resolveResult
    }
}

private func item(_ id: String) -> ForeignKeyItem {
    ForeignKeyItem(id: id, title: "Title \(id)")
}

final class ForeignKeyPickerModelTests: XCTestCase {

    @MainActor
    func testFirstLoadPopulatesItemsAndCursor() async {
        let client = MockSearchClient()
        client.pages = [ForeignKeyPage(items: [item("1"), item("2")], nextCursor: "c1")]
        let model = ForeignKeyPickerModel(client: client, endpoint: "stations", searchable: true)

        await model.load(reset: true)

        XCTAssertEqual(model.items.map(\.id), ["1", "2"])
        XCTAssertEqual(model.nextCursor, "c1")
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(client.requests, [.init(endpoint: "stations", query: nil, cursor: nil)])
    }

    @MainActor
    func testSearchQueryIsTrimmedAndPassedOnlyWhenSearchable() async {
        let client = MockSearchClient()
        let model = ForeignKeyPickerModel(client: client, endpoint: "stations", searchable: true)
        model.query = "  tokyo  "
        await model.load(reset: true)
        XCTAssertEqual(client.requests.last?.query, "tokyo")

        let unsearchable = ForeignKeyPickerModel(
            client: client, endpoint: "platforms", searchable: false)
        unsearchable.query = "ignored"
        await unsearchable.load(reset: true)
        XCTAssertNil(client.requests.last?.query)
    }

    @MainActor
    func testLoadMoreAppendsUsingCursor() async {
        let client = MockSearchClient()
        client.pages = [
            ForeignKeyPage(items: [item("1")], nextCursor: "c1"),
            ForeignKeyPage(items: [item("2")], nextCursor: nil),
        ]
        let model = ForeignKeyPickerModel(client: client, endpoint: "stations", searchable: true)

        await model.load(reset: true)
        await model.load(reset: false)

        XCTAssertEqual(model.items.map(\.id), ["1", "2"])
        XCTAssertNil(model.nextCursor)
        XCTAssertEqual(client.requests.last, .init(endpoint: "stations", query: nil, cursor: "c1"))
    }

    @MainActor
    func testLoadNextIfNeededOnlyFiresOnLastItemWithCursor() async {
        let client = MockSearchClient()
        client.pages = [
            ForeignKeyPage(items: [item("1"), item("2")], nextCursor: "c1"),
            ForeignKeyPage(items: [item("3")], nextCursor: nil),
        ]
        let model = ForeignKeyPickerModel(client: client, endpoint: "stations", searchable: true)
        await model.load(reset: true)

        // Not the last item — no request.
        await model.loadNextIfNeeded(item: item("1"))
        XCTAssertEqual(client.requests.count, 1)

        // Last item with a cursor — loads the next page.
        await model.loadNextIfNeeded(item: item("2"))
        XCTAssertEqual(model.items.map(\.id), ["1", "2", "3"])

        // Cursor exhausted — no request.
        await model.loadNextIfNeeded(item: item("3"))
        XCTAssertEqual(client.requests.count, 2)
    }

    @MainActor
    func testResetDropsStaleInFlightResults() async {
        let client = MockSearchClient()
        client.pages = [
            ForeignKeyPage(items: [item("stale")], nextCursor: "stale-cursor"),
            ForeignKeyPage(items: [item("fresh")], nextCursor: nil),
        ]
        client.gateFirstSearch = true
        let model = ForeignKeyPickerModel(client: client, endpoint: "stations", searchable: true)

        // First load suspends inside the client; a second reset load starts
        // and finishes while the first is still in flight.
        let first = Task { await model.load(reset: true) }
        while client.requests.count < 1 { await Task.yield() }
        await model.load(reset: true)
        XCTAssertEqual(model.items.map(\.id), ["fresh"])

        // Release the first request: its (stale-generation) result must be dropped.
        client.releaseGate()
        await first.value
        XCTAssertEqual(model.items.map(\.id), ["fresh"])
        XCTAssertNil(model.nextCursor)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testErrorSurfacesMessageAndMarksLoaded() async {
        let client = MockSearchClient()
        client.error = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "network down"])
        let model = ForeignKeyPickerModel(client: client, endpoint: "stations", searchable: true)

        await model.load(reset: true)

        XCTAssertEqual(model.errorMessage, "network down")
        XCTAssertTrue(model.hasLoaded)
        XCTAssertTrue(model.items.isEmpty)
    }

    // MARK: - Configuration defaults

    @MainActor
    func testDefaultTransformStoresID() async throws {
        let client = MockSearchClient()
        let configuration = ForeignKeyConfiguration(client: client)
        let schema = try JSONSchema(jsonString: #"{"type": "string"}"#)
        let context = ForeignKeyFieldContext(
            id: "root_stationId", propertyName: "stationId",
            endpoint: "stations", schema: schema, uiOptions: nil)

        let stored = configuration.transform(item("s1"), context)

        XCTAssertEqual(stored, .string("s1"))
        XCTAssertEqual(configuration.storedID(stored), "s1")
        XCTAssertNil(configuration.storedID(.string("")))
        XCTAssertNil(configuration.storedID(.null))
    }

    @MainActor
    func testCustomObjectTransformRoundTrips() async throws {
        let client = MockSearchClient()
        let configuration = ForeignKeyConfiguration(
            client: client,
            transform: { item, _ in
                item.raw ?? .object(properties: ["id": .string(item.id)])
            },
            storedID: { value in
                value.object?["id"]?.string
            }
        )
        let schema = try JSONSchema(jsonString: #"{"type": "object"}"#)
        let context = ForeignKeyFieldContext(
            id: "root_station", propertyName: "station",
            endpoint: "stations", schema: schema, uiOptions: nil)
        let record = ForeignKeyItem(
            id: "s1", title: "Tokyo",
            raw: .object(properties: ["id": .string("s1"), "name": .string("Tokyo")]))

        let stored = configuration.transform(record, context)

        XCTAssertEqual(stored.object?["name"], .string("Tokyo"))
        XCTAssertEqual(configuration.storedID(stored), "s1")
    }
}
