import SwiftUI

/// Form sections for page size, orientation, and light/dark page colors.
struct PaperForm: View {
    @Binding var paper: Paper
    var isPDF = false

    var body: some View {
        if !isPDF {
            Section("Page Size") {
                Picker("Size", selection: Binding(get: { paper.size }, set: { paper.setSize($0) })) {
                    ForEach(Paper.Size.allCases.filter { $0 != .pdf }) { size in
                        Text(size.title).tag(size)
                    }
                }
                if !paper.isInfinite {
                    Picker("Orientation", selection: Binding(get: { paper.isLandscape }, set: { paper.setLandscape($0) })) {
                        Text("Portrait").tag(false)
                        Text("Landscape").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if paper.size == .custom {
                    millimeterField("Width", value: $paper.width)
                    millimeterField("Height", value: $paper.height)
                }
            }
        }

        Section {
            ColorPicker("Light Mode", selection: color(\.light), supportsOpacity: false)
            if !isPDF {
                ColorPicker("Dark Mode", selection: color(\.dark), supportsOpacity: false)
            }
            Button("Reset Colors") { paper.color = .standard }
                .disabled(paper.color == .standard)
        } header: {
            Text("Page Color")
        } footer: {
            if isPDF {
                Text("PDFs are always shown on a light page, so ink stays readable on them.")
            }
        }
    }

    private func millimeterField(_ title: String, value: Binding<Double>) -> some View {
        let points = 72 / 25.4
        return LabeledContent(title) {
            TextField(title, value: Binding(
                get: { (value.wrappedValue / points).rounded() },
                set: { value.wrappedValue = max($0, 50) * points }
            ), format: .number)
            .multilineTextAlignment(.trailing)
            .keyboardType(.numberPad)
            Text("mm").foregroundStyle(.secondary)
        }
    }

    private func color(_ keyPath: WritableKeyPath<Paper.Colors, String>) -> Binding<Color> {
        Binding(
            get: { Color(uiColor: UIColor(hexRGBA: paper.color[keyPath: keyPath]) ?? .white) },
            set: { paper.color[keyPath: keyPath] = UIColor($0).hexRGBA }
        )
    }
}

/// Page setup for the open drawing.
struct PageSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var paper: Paper
    let isPDF: Bool
    let onSave: (Paper) -> Void

    init(paper: Paper, isPDF: Bool, onSave: @escaping (Paper) -> Void) {
        _paper = State(initialValue: paper)
        self.isPDF = isPDF
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                PaperForm(paper: $paper, isPDF: isPDF)
            }
            .navigationTitle("Page Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(paper)
                        dismiss()
                    }
                }
            }
        }
    }
}
