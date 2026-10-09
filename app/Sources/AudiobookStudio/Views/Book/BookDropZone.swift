import SwiftUI

/// "New audiobook" before a book is open: a drop area with an Open button, progress while the engine
/// reads the book (`inspect`), and the reason when it cannot (e.g. a scanned PDF that needs OCR).
/// Dropping works anywhere in the window (RootView handles it).
struct BookDropZone: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                dropArea
                if let error = model.bookError {
                    BookErrorView(error: error)
                        .frame(maxWidth: 560)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, minHeight: 480)
        }
    }

    private var dropArea: some View {
        VStack(spacing: 16) {
            Image(systemName: model.isInspecting ? "book.pages" : "books.vertical")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, isActive: model.isInspecting)
                .accessibilityHidden(true)

            if model.isInspecting {
                Text("Reading the book…")
                    .font(.title2.weight(.semibold))
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Reading the book")
                Text("Finding chapters, the cover and the language.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Drop a book here")
                    .font(.title2.weight(.semibold))
                Text("An EPUB or a PDF with selectable text. You choose the chapters and a voice; the audiobook is made on this Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.openWithPanel()
                } label: {
                    Label("Open Book…", systemImage: "folder")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Choose an EPUB or PDF (⌘O)")
                .accessibilityLabel("Open a book")
                .accessibilityHint("Shows a file picker for EPUB and PDF books")
            }
        }
        .padding(40)
        .frame(maxWidth: 560)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(nsColor: .tertiaryLabelColor), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop area for EPUB and PDF books")
    }
}
