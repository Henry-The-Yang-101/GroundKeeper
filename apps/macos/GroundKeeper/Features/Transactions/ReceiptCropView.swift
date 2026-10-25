import SwiftUI
import GroundKeeperCore

struct ReceiptCropSource: Identifiable {
    let id = UUID()
    let data: Data
}

struct ReceiptCropView: View {
    @Environment(\.dismiss) private var dismiss
    let source: ReceiptCropSource
    let onUse: (Data) -> Void
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var busy = false
    @State private var error: String?
    private var image: NSImage? { NSImage(data: source.data) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Crop receipt", subtitle: "Drag around the receipt, or adjust the edges below.")
            if let image {
                GeometryReader { geometry in
                    let scale = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
                        Path { path in
                            path.addRect(CGRect(origin: .zero, size: size))
                            path.addRect(CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                                                width: crop.width * size.width, height: crop.height * size.height))
                        }.fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                        Rectangle().stroke(.white, lineWidth: 2)
                            .frame(width: crop.width * size.width, height: crop.height * size.height)
                            .offset(x: crop.minX * size.width, y: crop.minY * size.height)
                    }
                    .contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                        let start = CGPoint(x: min(max(value.startLocation.x / size.width, 0), 1), y: min(max(value.startLocation.y / size.height, 0), 1))
                        let end = CGPoint(x: min(max(value.location.x / size.width, 0), 1), y: min(max(value.location.y / size.height, 0), 1))
                        guard abs(end.x - start.x) >= 0.01, abs(end.y - start.y) >= 0.01 else { return }
                        crop = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Receipt crop preview")
                }.padding(.horizontal, 24)
            }
            Grid(horizontalSpacing: 12, verticalSpacing: 6) {
                edgeSlider("Left", value: Binding(get: { crop.minX }, set: { crop = CGRect(x: $0, y: crop.minY, width: crop.maxX - $0, height: crop.height) }), range: 0...max(0.001, crop.maxX - 0.01))
                edgeSlider("Right", value: Binding(get: { crop.maxX }, set: { crop.size.width = $0 - crop.minX }), range: min(0.999, crop.minX + 0.01)...1)
                edgeSlider("Top", value: Binding(get: { crop.minY }, set: { crop = CGRect(x: crop.minX, y: $0, width: crop.width, height: crop.maxY - $0) }), range: 0...max(0.001, crop.maxY - 0.01))
                edgeSlider("Bottom", value: Binding(get: { crop.maxY }, set: { crop.size.height = $0 - crop.minY }), range: min(0.999, crop.minY + 0.01)...1)
            }.padding(24)
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal, 24) }
            SheetFooter {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Reset crop") { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Use receipt") { useReceipt() }.buttonStyle(.brass).keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 650, height: 700)
        .disabled(busy).interactiveDismissDisabled(busy)
    }

    private func edgeSlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        GridRow {
            Text(title).frame(width: 48, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel("Crop \(title.lowercased()) edge")
            Text(value.wrappedValue, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }

    private func useReceipt() {
        busy = true; error = nil
        let data = source.data, crop = crop
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try ReceiptImageProcessor.jpeg(data, crop: crop) }.value
                onUse(result); dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
