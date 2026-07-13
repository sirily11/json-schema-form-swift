import JSONSchema
import SwiftUI

/// Renders a foreign-key field (`ui:widget: "foreign-key"`) as a row that
/// pushes a dedicated searchable, paginated picker page.
///
/// The field is configuration-driven: the schema's `ui:options.endpoint`
/// names the record collection, while the app-injected
/// `ForeignKeyConfiguration` (via `JSONSchemaForm(foreignKey:)`) supplies the
/// authenticated search client and the transform that converts a picked item
/// into stored FormData. Without a configuration or endpoint the field falls
/// back to a plain string input so schemas stay editable.
struct ForeignKeyField: Field {
    static let widgetName = "foreign-key"

    var schema: JSONSchema
    var uiSchema: [String: Any]?
    var id: String
    var formData: Binding<FormData>
    var required: Bool
    var propertyName: String?
    /// App-supplied configuration, threaded down from
    /// `JSONSchemaForm(foreignKey:)` alongside `widgets`.
    var configuration: ForeignKeyConfiguration?

    /// Title of the item picked in this session, shown without a resolve
    /// round-trip.
    @State private var pickedTitle: String?
    /// Title resolved from the stored id via the client.
    @State private var resolvedTitle: String?

    private var uiOptions: [String: Any]? {
        getUiOptions(uiSchema: uiSchema, globalUiOptions: nil)
    }

    private var endpoint: String? {
        uiOptions?["endpoint"] as? String
    }

    private var searchable: Bool {
        uiOptions?["searchable"] as? Bool ?? true
    }

    private var accessibilityID: String {
        uiOptions?["accessibility_id"] as? String ?? id
    }

    private var rowTitle: String {
        fieldTitle.isEmpty ? (propertyName ?? "") : fieldTitle
    }

    var body: some View {
        if let configuration, let endpoint {
            selectionRow(configuration: configuration, endpoint: endpoint)
        } else {
            // No app configuration (or no endpoint in ui:options) — degrade
            // to the plain string input so the value stays editable.
            StringField(
                schema: schema,
                uiSchema: uiSchema,
                id: id,
                formData: formData,
                required: required,
                propertyName: propertyName
            )
        }
    }

    private func selectionRow(
        configuration: ForeignKeyConfiguration, endpoint: String
    ) -> some View {
        let context = ForeignKeyFieldContext(
            id: id,
            propertyName: propertyName,
            endpoint: endpoint,
            schema: schema,
            uiOptions: uiOptions
        )
        let storedID = configuration.storedID(formData.wrappedValue)

        return NavigationLink {
            ForeignKeyPickerView(
                title: rowTitle,
                configuration: configuration,
                context: context,
                searchable: searchable,
                required: required,
                formData: formData,
                onPicked: { item in
                    pickedTitle = item?.title
                    resolvedTitle = nil
                }
            )
        } label: {
            HStack {
                Text(rowTitle)
                    .foregroundStyle(.primary)
                Spacer()
                Text(displayValue(storedID: storedID))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .id("\(id)_foreignkey")
        .accessibilityIdentifier(accessibilityID)
        .task(id: storedID) {
            await resolveTitleIfNeeded(
                configuration: configuration, endpoint: endpoint, storedID: storedID)
        }
    }

    private func displayValue(storedID: String?) -> String {
        guard storedID != nil else { return "None" }
        return pickedTitle ?? resolvedTitle ?? storedID ?? "None"
    }

    /// Resolves the stored id to a human-readable title through the client.
    /// Skipped when the title is already known from an in-session pick.
    private func resolveTitleIfNeeded(
        configuration: ForeignKeyConfiguration, endpoint: String, storedID: String?
    ) async {
        guard pickedTitle == nil, resolvedTitle == nil, let storedID else { return }
        guard
            let item = try? await configuration.client.resolve(endpoint: endpoint, id: storedID)
        else { return }
        resolvedTitle = item.title
    }
}
