import JSONSchema
import SwiftUI

/// Dedicated foreign-key picker page, pushed from `ForeignKeyField`.
///
/// Shows a searchable (when the field's `ui:options.searchable` is not
/// false), lazily paginated list of records fetched through the app's
/// `ForeignKeySearchClient`. Selecting a row runs the configuration's
/// transform, writes the result into the form data, and pops back.
struct ForeignKeyPickerView: View {
    let title: String
    let configuration: ForeignKeyConfiguration
    let context: ForeignKeyFieldContext
    let searchable: Bool
    let required: Bool
    var formData: Binding<FormData>
    /// Reports the picked item (nil when cleared) so the field row can show
    /// the new title without a resolve round-trip.
    let onPicked: (ForeignKeyItem?) -> Void

    @State private var model: ForeignKeyPickerModel
    @Environment(\.dismiss) private var dismiss

    /// `model` is injectable for tests; production callers let the view
    /// create its own.
    init(
        title: String,
        configuration: ForeignKeyConfiguration,
        context: ForeignKeyFieldContext,
        searchable: Bool,
        required: Bool,
        formData: Binding<FormData>,
        onPicked: @escaping (ForeignKeyItem?) -> Void,
        model: ForeignKeyPickerModel? = nil
    ) {
        self.title = title
        self.configuration = configuration
        self.context = context
        self.searchable = searchable
        self.required = required
        self.formData = formData
        self.onPicked = onPicked
        _model = State(
            initialValue: model
                ?? ForeignKeyPickerModel(
                    client: configuration.client,
                    endpoint: context.endpoint,
                    searchable: searchable
                ))
    }

    private var storedID: String? {
        configuration.storedID(formData.wrappedValue)
    }

    var body: some View {
        list
            .navigationTitle(title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .modifier(SearchableIfNeeded(searchable: searchable, query: $model.query))
            .task(id: model.query) {
                if model.hasLoaded {
                    // Debounce keystrokes: `.task(id:)` cancels the previous
                    // task on every query change, so the sleep only survives
                    // once typing pauses.
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                }
                await model.load(reset: true)
            }
            .overlay { stateOverlay }
    }

    private var list: some View {
        List {
            if !required, model.hasLoaded {
                Button {
                    select(nil)
                } label: {
                    HStack {
                        Text("None")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if storedID == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityIdentifier("\(context.id)_foreignkey_none")
            }

            ForEach(model.items) { item in
                Button {
                    select(item)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .foregroundStyle(.primary)
                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if item.id == storedID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .onAppear {
                    Task { await model.loadNextIfNeeded(item: item) }
                }
            }

            if model.isLoading, !model.items.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .accessibilityIdentifier("\(context.id)_foreignkey_picker")
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if !model.hasLoaded {
            ProgressView()
        } else if let errorMessage = model.errorMessage, model.items.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") {
                    Task { await model.load(reset: true) }
                }
            }
        } else if model.items.isEmpty {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text(
                    model.query.isEmpty
                        ? "No records available." : "No records match \"\(model.query)\".")
            )
        }
    }

    private func select(_ item: ForeignKeyItem?) {
        if let item {
            formData.wrappedValue = configuration.transform(item, context)
        } else {
            formData.wrappedValue = .null
        }
        onPicked(item)
        dismiss()
    }
}

/// Applies `.searchable` only when the field is searchable, so
/// non-searchable endpoints get a plain list.
private struct SearchableIfNeeded: ViewModifier {
    let searchable: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if searchable {
            content.searchable(text: $query, prompt: "Search")
        } else {
            content
        }
    }
}
