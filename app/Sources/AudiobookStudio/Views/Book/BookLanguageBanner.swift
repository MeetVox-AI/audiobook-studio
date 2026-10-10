import SwiftUI

/// Shown on the book screen when the book's language is one of the registry languages that is switched off:
/// "This book is in Spanish. Add Spanish to choose a narrator", with the button that turns it on (downloads its
/// small reference voices) and what that costs. Nothing else is downloaded.
struct BookLanguageBanner: View {
    @Environment(AppModel.self) private var model
    let language: LanguageInfo

    var body: some View {
        let download = model.languageDownloads[language.code]
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            InlineBanner(systemImage: "globe", tint: Theme.accent) {
                HStack(alignment: .center, spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("This book is in \(language.name). Add \(language.name) to choose a narrator")
                            .fixedSize(horizontal: false, vertical: true)
                        if let download {
                            Text(download.statusText)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(model.languageAddHint(language))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if download != nil {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Adding \(language.name)")
                    } else {
                        Button("Add \(language.name)") {
                            Task { try? await model.addLanguage(language.code) }
                        }
                        .bookCardButton(prominent: true)
                        .controlSize(.small)
                        .disabled(model.isChangingLanguage)
                        .accessibilityLabel("Add \(language.name) and download its voices")
                        .help("Turns \(language.name) on and downloads its reference voices")
                    }
                }
            }
            .font(.callout)
            .accessibilityElement(children: .contain)
            if let error = model.languageErrors[language.code] {
                BookErrorView(error: error) { model.clearLanguageMessages(language.code) }
            }
        }
    }
}
