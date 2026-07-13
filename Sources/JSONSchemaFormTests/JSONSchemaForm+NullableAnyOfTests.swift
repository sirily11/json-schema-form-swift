import JSONSchema
import SwiftUI
import ViewInspector
import XCTest

@testable import JSONSchemaForm

/// Tests for nullable-wrapper anyOf schemas (`anyOf: [X, {"type": "null"}]`), the
/// shape OpenAPI-derived backends emit for nullable fields.
class JSONSchemaFormNullableAnyOfTests: XCTestCase {
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 30
    }

    /// Object with nullable string and nullable enum properties, as served by an
    /// OpenAPI-backed schema endpoint (no preprocessing applied).
    private let nullablePropertiesSchema = """
        {
          "type": "object",
          "properties": {
            "website": {
              "anyOf": [
                {
                  "type": "string",
                  "title": "Website",
                  "description": "Official website URL."
                },
                { "type": "null" }
              ]
            },
            "companyType": {
              "anyOf": [
                {
                  "type": "string",
                  "title": "Company Type",
                  "enum": ["jr", "major_private", "other"]
                },
                { "type": "null" }
              ]
            }
          },
          "required": []
        }
        """

    /// A genuine multi-branch anyOf (no null branch) must keep the selector UI.
    private let multiBranchAnyOfSchema = """
        {
          "type": "object",
          "anyOf": [
            {
              "type": "object",
              "properties": {
                "lorem": { "type": "string" }
              },
              "required": ["lorem"]
            },
            {
              "type": "object",
              "properties": {
                "ipsum": { "type": "string" }
              },
              "required": ["ipsum"]
            },
            {
              "type": "object",
              "properties": {
                "dolor": { "type": "string" }
              },
              "required": ["dolor"]
            }
          ]
        }
        """

    /// A nullable string property renders as a plain text field with its title
    /// and current value, instead of rendering nothing.
    @MainActor
    func testNullableAnyOf_StringFieldRenders() async throws {
        let schema = try JSONSchema(jsonString: nullablePropertiesSchema)
        let formData = FormData.object(properties: [
            "website": .string("https://example.com")
        ])
        let data = Binding(wrappedValue: formData)
        let form = JSONSchemaForm(schema: schema, formData: data)

        let websiteField = try form.inspect().find(viewWithId: "root_website").find(ViewType.TextField.self)
        XCTAssertEqual(try websiteField.input(), "https://example.com")

        XCTAssertNoThrow(
            try form.inspect().find(text: "Website"),
            "Title from the non-null branch should be used as the field label"
        )
    }

    /// A nullable enum property renders the enum dropdown from the non-null branch.
    @MainActor
    func testNullableAnyOf_EnumFieldRendersPicker() async throws {
        let schema = try JSONSchema(jsonString: nullablePropertiesSchema)
        let formData = FormData.object(properties: [
            "companyType": .string("jr")
        ])
        let data = Binding(wrappedValue: formData)
        let form = JSONSchemaForm(schema: schema, formData: data)

        let enumField = try form.inspect().find(viewWithId: "root_companyType_enum_field")
        XCTAssertNoThrow(try enumField.find(ViewType.Picker.self), "Nullable enum should render a picker")
    }

    /// Editing a nullable string field updates the bound form data.
    @MainActor
    func testNullableAnyOf_EditUpdatesFormData() async throws {
        let schema = try JSONSchema(jsonString: nullablePropertiesSchema)
        let formData = FormData.object(properties: [
            "website": .string("https://old.example")
        ])
        let data = Binding(wrappedValue: formData)
        let form = JSONSchemaForm(schema: schema, formData: data)

        let textField = try form.inspect().find(viewWithId: "root_website").find(ViewType.TextField.self)
        let customField = try form.inspect().find(viewWithId: "root_website_string_field")

        try textField.setInput("https://new.example")
        try customField.callOnChange(oldValue: "https://old.example", newValue: "https://new.example")

        XCTAssertEqual(data.wrappedValue.object?["website"], .string("https://new.example"))
    }

    /// A three-branch anyOf is not a nullable wrapper and must render the
    /// option selector (OneOfField path).
    @MainActor
    func testMultiBranchAnyOf_RendersSelector() async throws {
        let schema = try JSONSchema(jsonString: multiBranchAnyOfSchema)
        let formData = FormData.object(properties: [
            "lorem": .string("test")
        ])
        let data = Binding(wrappedValue: formData)
        let form = JSONSchemaForm(schema: schema, formData: data)

        let picker = try form.inspect().find(viewWithId: "root_oneOf_picker")
        XCTAssertNotNil(picker, "Multi-branch anyOf should render the option selector")
    }

    /// The nullable-wrapper detection itself: two branches, one null.
    func testNullableBranchDetection() throws {
        let schema = try JSONSchema(jsonString: nullablePropertiesSchema)
        let website = schema.objectSchema?.properties?["website"]
        XCTAssertEqual(website?.type, .anyOf)
        XCTAssertEqual(website?.combinedSchema?.anyOf?.count, 2)
        XCTAssertTrue(website?.combinedSchema?.anyOf?.contains { $0.type == .null } ?? false)
    }
}
