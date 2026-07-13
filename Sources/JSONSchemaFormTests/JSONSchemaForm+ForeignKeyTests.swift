import JSONSchema
import SwiftUI
import ViewInspector
import XCTest

@testable import JSONSchemaForm

/// Simple stub client for rendering tests.
@MainActor
private final class StubSearchClient: ForeignKeySearchClient {
    var page = ForeignKeyPage(items: [], nextCursor: nil)
    var resolveResult: ForeignKeyItem?

    func search(endpoint: String, query: String?, cursor: String?) async throws -> ForeignKeyPage {
        page
    }

    func resolve(endpoint: String, id: String) async throws -> ForeignKeyItem? {
        resolveResult
    }
}

final class JSONSchemaFormForeignKeyTests: XCTestCase {

    private let schemaJSON = """
        {
            "type": "object",
            "properties": {
                "stationId": { "type": "string", "title": "Station" }
            }
        }
        """

    private let uiSchema: [String: Any] = [
        "stationId": [
            "ui:widget": "foreign-key",
            "ui:options": [
                "endpoint": "stations",
                "searchable": true,
                "accessibility_id": "form.route-station.stationId",
            ],
        ]
    ]

    @MainActor
    func testForeignKeyWidgetRendersNavigationLinkRow() async throws {
        let schema = try JSONSchema(jsonString: schemaJSON)
        let data = Binding(wrappedValue: FormData.object(properties: [
            "stationId": .string("")
        ]))
        let form = JSONSchemaForm(
            schema: schema,
            uiSchema: uiSchema,
            formData: data,
            foreignKey: ForeignKeyConfiguration(client: StubSearchClient())
        )

        let row = try form.inspect().find(viewWithId: "root_stationId_foreignkey")
        XCTAssertNotNil(row)
        let link = try row.find(ViewType.NavigationLink.self)
        XCTAssertNotNil(link)

        // The row shows the field title and "None" for an empty selection.
        XCTAssertNoThrow(try row.find(text: "Station"))
        XCTAssertNoThrow(try row.find(text: "None"))
    }

    @MainActor
    func testForeignKeyRowShowsStoredIDBeforeResolve() async throws {
        let schema = try JSONSchema(jsonString: schemaJSON)
        let data = Binding(wrappedValue: FormData.object(properties: [
            "stationId": .string("station-42")
        ]))
        let form = JSONSchemaForm(
            schema: schema,
            uiSchema: uiSchema,
            formData: data,
            foreignKey: ForeignKeyConfiguration(client: StubSearchClient())
        )

        // Before (or without) resolve, the raw stored id is displayed.
        let row = try form.inspect().find(viewWithId: "root_stationId_foreignkey")
        XCTAssertNoThrow(try row.find(text: "station-42"))
    }

    @MainActor
    func testWithoutConfigurationFallsBackToStringField() async throws {
        let schema = try JSONSchema(jsonString: schemaJSON)
        let data = Binding(wrappedValue: FormData.object(properties: [
            "stationId": .string("station-42")
        ]))
        let form = JSONSchemaForm(
            schema: schema,
            uiSchema: uiSchema,
            formData: data
        )

        // No foreignKey configuration — a plain text input renders instead.
        let textWidget = try form.inspect().find(viewWithId: "root_stationId_text")
        let textField = try textWidget.find(ViewType.TextField.self)
        XCTAssertEqual(try textField.input(), "station-42")
        XCTAssertThrowsError(
            try form.inspect().find(ViewType.NavigationLink.self))
    }

    @MainActor
    func testWithoutEndpointFallsBackToStringField() async throws {
        let schema = try JSONSchema(jsonString: schemaJSON)
        let data = Binding(wrappedValue: FormData.object(properties: [
            "stationId": .string("x")
        ]))
        let noEndpointUiSchema: [String: Any] = [
            "stationId": ["ui:widget": "foreign-key"]
        ]
        let form = JSONSchemaForm(
            schema: schema,
            uiSchema: noEndpointUiSchema,
            formData: data,
            foreignKey: ForeignKeyConfiguration(client: StubSearchClient())
        )

        XCTAssertNotNil(try form.inspect().find(viewWithId: "root_stationId_text"))
        XCTAssertThrowsError(
            try form.inspect().find(ViewType.NavigationLink.self))
    }

    @MainActor
    func testAppRegisteredWidgetOverridesBuiltInForeignKey() async throws {
        let schema = try JSONSchema(jsonString: schemaJSON)
        let data = Binding(wrappedValue: FormData.object(properties: [
            "stationId": .string("")
        ]))
        let form = JSONSchemaForm(
            schema: schema,
            uiSchema: uiSchema,
            formData: data,
            widgets: [
                "foreign-key": { _ in AnyView(Text("custom-relation-widget")) }
            ],
            foreignKey: ForeignKeyConfiguration(client: StubSearchClient())
        )

        XCTAssertNoThrow(try form.inspect().find(text: "custom-relation-widget"))
        XCTAssertThrowsError(
            try form.inspect().find(viewWithId: "root_stationId_foreignkey"))
    }

    @MainActor
    func testNullableAnyOfForeignKeyRendersRow() async throws {
        let nullableSchemaJSON = """
            {
                "type": "object",
                "properties": {
                    "stationId": {
                        "anyOf": [
                            { "type": "string", "title": "Station" },
                            { "type": "null" }
                        ]
                    }
                }
            }
            """
        let schema = try JSONSchema(jsonString: nullableSchemaJSON)
        let data = Binding(wrappedValue: FormData.object(properties: [
            "stationId": .string("")
        ]))
        let form = JSONSchemaForm(
            schema: schema,
            uiSchema: uiSchema,
            formData: data,
            foreignKey: ForeignKeyConfiguration(client: StubSearchClient())
        )

        let row = try form.inspect().find(viewWithId: "root_stationId_foreignkey")
        XCTAssertNotNil(try row.find(ViewType.NavigationLink.self))
    }

    @MainActor
    func testPickerSelectionWritesTransformedValue() async throws {
        let client = StubSearchClient()
        client.page = ForeignKeyPage(
            items: [ForeignKeyItem(id: "s9", title: "Osaka", subtitle: "Kansai")],
            nextCursor: nil)
        let configuration = ForeignKeyConfiguration(client: client)
        let schema = try JSONSchema(jsonString: #"{"type": "string"}"#)
        let context = ForeignKeyFieldContext(
            id: "root_stationId", propertyName: "stationId",
            endpoint: "stations", schema: schema, uiOptions: nil)
        let data = Binding(wrappedValue: FormData.string(""))
        var picked: ForeignKeyItem?

        // Inject a preloaded model so rows are inspectable without driving
        // the async .task.
        let model = ForeignKeyPickerModel(
            client: client, endpoint: "stations", searchable: true)
        await model.load(reset: true)

        let picker = ForeignKeyPickerView(
            title: "Station",
            configuration: configuration,
            context: context,
            searchable: true,
            required: true,
            formData: data,
            onPicked: { picked = $0 },
            model: model
        )

        // Tapping a row runs the transform, writes the value, and reports
        // the picked item.
        let row = try picker.inspect().find(button: "Osaka")
        try row.tap()

        XCTAssertEqual(data.wrappedValue, .string("s9"))
        XCTAssertEqual(picked?.id, "s9")
    }

    @MainActor
    func testPickerNoneRowClearsOptionalValue() async throws {
        let client = StubSearchClient()
        client.page = ForeignKeyPage(
            items: [ForeignKeyItem(id: "s1", title: "Tokyo")], nextCursor: nil)
        let configuration = ForeignKeyConfiguration(client: client)
        let schema = try JSONSchema(jsonString: #"{"type": "string"}"#)
        let context = ForeignKeyFieldContext(
            id: "root_stationId", propertyName: "stationId",
            endpoint: "stations", schema: schema, uiOptions: nil)
        let data = Binding(wrappedValue: FormData.string("s1"))
        var picked: ForeignKeyItem? = ForeignKeyItem(id: "sentinel", title: "sentinel")

        let model = ForeignKeyPickerModel(
            client: client, endpoint: "stations", searchable: true)
        await model.load(reset: true)

        let picker = ForeignKeyPickerView(
            title: "Station",
            configuration: configuration,
            context: context,
            searchable: true,
            required: false,
            formData: data,
            onPicked: { picked = $0 },
            model: model
        )

        let noneRow = try picker.inspect().find(button: "None")
        try noneRow.tap()

        XCTAssertEqual(data.wrappedValue, .null)
        XCTAssertNil(picked)
    }
}
