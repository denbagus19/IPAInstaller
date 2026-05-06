import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MobileCoreServices

// MARK: - Document Picker (UIKit-based, reliable on sideloaded apps)

struct DocumentPicker: UIViewControllerRepresentable {
    var allowedExtensions: [String]
    var onPicked: (URL) -> Void
    var onError: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Use .item to show all files in Files app
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .fullScreen
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker

        init(_ parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }

            let ext = url.pathExtension.lowercased()
            let allowed = parent.allowedExtensions.map { $0.lowercased() }

            if !allowed.isEmpty && !allowed.contains(ext) {
                parent.onError?("File harus berekstensi: \(parent.allowedExtensions.joined(separator: ", ")). Anda memilih: .\(ext)")
                return
            }

            parent.onPicked(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // User cancelled, do nothing
        }
    }
}
