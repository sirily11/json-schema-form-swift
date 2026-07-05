import JSONSchema
import SwiftUI
import ViewInspector
import XCTest

@testable import JSONSchemaForm

/// Tests for object-level if/then/else conditionals: an object schema can
/// declare `if`/`then`/`else` and its conditional properties show/hide based
/// on the object's own form data, without switching the root to AllOfField
/// (so custom widgets, templates and ui:order keep working).
class JSONSchemaFormObjectConditionalTests: XCTestCase {
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 30
    }

    /// Mirrors the shape of a real server-driven form: a nested "settings"
    /// object whose "discussants" field only exists when type == "discussion".
    private let settingsSchemaJSON = """
        {
            "type": "object",
            "properties": {
                "topic": { "type": "string" },
                "settings": {
                    "type": "object",
                    "properties": {
                        "type": { "type": "string", "enum": ["discussion", "audio-book"] },
                        "language": { "type": "string" }
                    },
                    "required": ["type", "language"],
                    "if": {
                        "properties": { "type": { "const": "discussion" } },
                        "required": ["type"]
                    },
                    "then": {
                        "properties": {
                            "discussants": { "type": "integer", "minimum": 2, "maximum": 6, "default": 3 }
                        },
                        "required": ["discussants"]
                    }
                }
            }
        }
        """

    private func formData(type: String) -> FormData {
        FormData.object(properties: [
            "topic": .string("hello"),
            "settings": .object(properties: [
                "type": .string(type),
                "language": .string("en-US"),
                "discussants": .number(3),
            ]),
        ])
    }

    // MARK: - Extractor unit tests

    @MainActor
    func testExtractorFindsNestedConditionals() async throws {
        let result = ObjectConditionalExtractor.extract(from: settingsSchemaJSON)
        XCTAssertNotNil(result, "Extractor should find the settings conditional")
        let conditionals = result?["root_settings"] ?? []
        XCTAssertEqual(conditionals.count, 1, "settings should carry exactly one conditional")
        XCTAssertNotNil(conditionals[0].thenSchema, "then schema should be captured")
        XCTAssertNil(conditionals[0].elseSchema, "no else schema declared")
        XCTAssertNil(result?["root"], "root object declares no conditional")
    }

    @MainActor
    func testExtractorReturnsNilWithoutConditionals() async throws {
        let plain = """
            { "type": "object", "properties": { "name": { "type": "string" } } }
            """
        XCTAssertNil(ObjectConditionalExtractor.extract(from: plain))
    }

    @MainActor
    func testExtractorCapturesElseBranch() async throws {
        let withElse = """
            {
                "type": "object",
                "properties": { "kind": { "type": "string" } },
                "if": { "properties": { "kind": { "const": "a" } } },
                "then": { "properties": { "fieldA": { "type": "string" } } },
                "else": { "properties": { "fieldB": { "type": "string" } } }
            }
            """
        let result = ObjectConditionalExtractor.extract(from: withElse)
        let conditionals = result?["root"] ?? []
        XCTAssertEqual(conditionals.count, 1)
        XCTAssertNotNil(conditionals[0].thenSchema)
        XCTAssertNotNil(conditionals[0].elseSchema)
    }

    // MARK: - Rendering

    @MainActor
    func testConditionalFieldVisibleWhenConditionMatches() async throws {
        let schema = try JSONSchema(jsonString: settingsSchemaJSON)
        let data = Binding(wrappedValue: formData(type: "discussion"))
        let form = JSONSchemaForm(
            schema: schema, formData: data, schemaJSON: settingsSchemaJSON)

        let view = try form.inspect()
        XCTAssertNoThrow(
            try view.find(viewWithId: "root_settings_discussants"),
            "discussants should render for type=discussion")
        XCTAssertNoThrow(try view.find(viewWithId: "root_settings_type"))
        XCTAssertNoThrow(try view.find(viewWithId: "root_settings_language"))
    }

    @MainActor
    func testConditionalFieldHiddenWhenConditionFails() async throws {
        let schema = try JSONSchema(jsonString: settingsSchemaJSON)
        let data = Binding(wrappedValue: formData(type: "audio-book"))
        let form = JSONSchemaForm(
            schema: schema, formData: data, schemaJSON: settingsSchemaJSON)

        let view = try form.inspect()
        XCTAssertThrowsError(
            try view.find(viewWithId: "root_settings_discussants"),
            "discussants should be hidden for type=audio-book")
        // Base fields keep rendering.
        XCTAssertNoThrow(try view.find(viewWithId: "root_settings_type"))
        XCTAssertNoThrow(try view.find(viewWithId: "root_settings_language"))
        // The hidden field's value is intentionally left in formData so it
        // restores when the condition flips back.
        let settings = data.wrappedValue.object?["settings"]?.object
        XCTAssertEqual(settings?["discussants"], .number(3))
    }

    @MainActor
    func testConditionalHiddenEvenWithCustomWidgetInUiOrder() async throws {
        let schema = try JSONSchema(jsonString: settingsSchemaJSON)
        let uiSchema: [String: Any] = [
            "settings": [
                "ui:order": ["type", "discussants", "language"],
                "discussants": ["ui:widget": "stepper"],
            ]
        ]
        let widgets: [String: JSONSchemaFormWidget] = [
            "stepper": { _ in AnyView(Text("Panelists Row").id("panelists_widget")) }
        ]

        // Hidden: the ui:order + custom-widget fallback must not resurrect it.
        let hiddenData = Binding(wrappedValue: formData(type: "audio-book"))
        let hiddenForm = JSONSchemaForm(
            schema: schema, uiSchema: uiSchema, formData: hiddenData,
            schemaJSON: settingsSchemaJSON, widgets: widgets)
        XCTAssertThrowsError(
            try hiddenForm.inspect().find(viewWithId: "panelists_widget"),
            "custom widget must not render while the conditional hides the key")

        // Visible: same setup, matching condition.
        let visibleData = Binding(wrappedValue: formData(type: "discussion"))
        let visibleForm = JSONSchemaForm(
            schema: schema, uiSchema: uiSchema, formData: visibleData,
            schemaJSON: settingsSchemaJSON, widgets: widgets)
        XCTAssertNoThrow(
            try visibleForm.inspect().find(viewWithId: "panelists_widget"),
            "custom widget should render when the condition matches")
    }

    @MainActor
    func testElseBranchRendersWhenConditionFails() async throws {
        let schemaJSON = """
            {
                "type": "object",
                "properties": { "kind": { "type": "string" } },
                "if": { "properties": { "kind": { "const": "a" } } },
                "then": { "properties": { "fieldA": { "type": "string" } } },
                "else": { "properties": { "fieldB": { "type": "string" } } }
            }
            """
        let schema = try JSONSchema(jsonString: schemaJSON)

        let dataA = Binding(
            wrappedValue: FormData.object(properties: ["kind": .string("a")]))
        let formA = JSONSchemaForm(schema: schema, formData: dataA, schemaJSON: schemaJSON)
        let viewA = try formA.inspect()
        XCTAssertNoThrow(try viewA.find(viewWithId: "root_fieldA"))
        XCTAssertThrowsError(try viewA.find(viewWithId: "root_fieldB"))

        let dataB = Binding(
            wrappedValue: FormData.object(properties: ["kind": .string("b")]))
        let formB = JSONSchemaForm(schema: schema, formData: dataB, schemaJSON: schemaJSON)
        let viewB = try formB.inspect()
        XCTAssertThrowsError(try viewB.find(viewWithId: "root_fieldA"))
        XCTAssertNoThrow(try viewB.find(viewWithId: "root_fieldB"))
    }

    @MainActor
    func testConditionFlipRestoresField() async throws {
        let schema = try JSONSchema(jsonString: settingsSchemaJSON)
        var data = formData(type: "audio-book")
        let binding = Binding(get: { data }, set: { data = $0 })

        var form = JSONSchemaForm(schema: schema, formData: binding, schemaJSON: settingsSchemaJSON)
        XCTAssertThrowsError(try form.inspect().find(viewWithId: "root_settings_discussants"))

        // Flip the type back to discussion: the field (and its retained value)
        // must come back.
        data = formData(type: "discussion")
        form = JSONSchemaForm(schema: schema, formData: binding, schemaJSON: settingsSchemaJSON)
        XCTAssertNoThrow(try form.inspect().find(viewWithId: "root_settings_discussants"))
        XCTAssertEqual(data.object?["settings"]?.object?["discussants"], .number(3))
    }
}
