import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let doneButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        receiveFirstFile()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        titleLabel.text = "In Echo importieren"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center
        messageLabel.text = "Dokument wird übernommen…"
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        spinner.startAnimating()
        doneButton.setTitle("Fertig", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.isHidden = true
        doneButton.addTarget(self, action: #selector(finish), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, spinner, messageLabel, doneButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    private func receiveFirstFile() {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []
        guard let provider = providers.first,
              let typeIdentifier = preferredTypeIdentifier(from: provider)
        else {
            show(error: "Goodnotes hat Echo keine lesbare Datei übergeben.")
            return
        }

        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
            do {
                guard let url else { throw error ?? PendingNoteImports.StorageError.unreadableFile }
                let filename = Self.filename(for: provider, source: url, typeIdentifier: typeIdentifier)
                _ = try PendingNoteImports.enqueue(from: url, suggestedName: filename)
                DispatchQueue.main.async {
                    self?.showSuccess()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.show(error: error.localizedDescription)
                }
            }
        }
    }

    private func preferredTypeIdentifier(from provider: NSItemProvider) -> String? {
        let preferredExtensions = ["goodnotes", "note", "pdf", "png", "jpg", "jpeg"]
        return provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return preferredExtensions.contains(type.preferredFilenameExtension?.lowercased() ?? "")
        } ?? provider.registeredTypeIdentifiers.first
    }

    private nonisolated static func filename(
        for provider: NSItemProvider,
        source: URL,
        typeIdentifier: String
    ) -> String {
        var filename = provider.suggestedName ?? source.lastPathComponent
        let existingExtension = URL(fileURLWithPath: filename).pathExtension
        if existingExtension.isEmpty, let preferredExtension = fileExtension(for: typeIdentifier) {
            filename += ".\(preferredExtension)"
        }
        return filename
    }

    private nonisolated static func fileExtension(for typeIdentifier: String) -> String? {
        if let known = UTType(typeIdentifier)?.preferredFilenameExtension { return known }
        let lowered = typeIdentifier.lowercased()
        if lowered.contains("goodnotes") { return "goodnotes" }
        if lowered.contains("notability") { return "note" }
        return nil
    }

    private func showSuccess() {
        spinner.stopAnimating()
        messageLabel.text = "Gespeichert. Öffne in Echo die gewünschte Stunde und wähle "
            + "„Unterrichtsnotizen“, um den Import abzuschließen."
        doneButton.isHidden = false
    }

    private func show(error: String) {
        spinner.stopAnimating()
        messageLabel.textColor = .systemRed
        messageLabel.text = error
        doneButton.isHidden = false
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
