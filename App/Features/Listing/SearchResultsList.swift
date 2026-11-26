import HeydayKit
import SwiftUI

/// The middle column while a search is on.
struct SearchResultsList: View {
    let query: String
    let workspace: Workspace

    private var store: Store<SearchFeature> { workspace.search(query) }

    var body: some View {
        Group {
            switch store.state.results {
            case .searching:
                ConversationListPlaceholder()
            case .unavailable(let error):
                ContentUnavailableView {
                    Label("Search Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.userMessage)
                } actions: {
                    Button("Try Again") { store.send(.opened) }
                }
            case .found(let conversations) where conversations.isEmpty:
                ContentUnavailableView.search(text: query)
            case .found(let conversations):
                ConversationList(sections: [.init(title: nil, conversations: conversations)], workspace: workspace) {}
            }
        }
        .navigationTitle("Search")
        .subtitled("“\(query)”")
        .task(id: query) {
            store.send(.opened)
        }
    }
}
