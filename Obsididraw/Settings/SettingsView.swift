import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @AppStorage("allowsFingerDrawing") private var allowsFingerDrawing = false
    @State private var defaultPaper = Paper.defaultForNewDrawings

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                #if !targetEnvironment(macCatalyst)
                Section {
                    Toggle("Draw with Finger", isOn: $allowsFingerDrawing)
                } header: {
                    Text("Apple Pencil")
                } footer: {
                    Text("When off, only Apple Pencil draws and fingers scroll.")
                }
                #endif

                Section("New Drawings") {
                    Text("The page size, template and colors below apply to drawings you create from now on. To change an existing drawing, use Page Setup in its toolbar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                PaperForm(paper: $defaultPaper)
            }
            .onChange(of: defaultPaper) { _, paper in Paper.defaultForNewDrawings = paper }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
