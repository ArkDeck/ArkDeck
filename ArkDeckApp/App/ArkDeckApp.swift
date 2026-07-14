import ArkDeckCore
import SwiftUI

@main
struct ArkDeckApp: App {
    var body: some Scene {
        WindowGroup {
            AppShellView()
        }
    }
}

private struct AppShellView: View {
    @State private var selection: ArkDeckNavigationItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(ArkDeckNavigationItem.allCases, selection: $selection) { item in
                Label {
                    Text(LocalizedStringKey(item.localizationKey))
                } icon: {
                    Image(systemName: item.systemImageName)
                }
            }
            .navigationTitle("app.shell.title")
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                Text(LocalizedStringKey(selection?.localizationKey ?? ArkDeckNavigationItem.overview.localizationKey))
                    .font(.largeTitle)
                Text("app.shell.status")
                    .font(.headline)
                Text("app.shell.nonDestructiveNote")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(32)
            .navigationTitle("app.shell.title")
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}
