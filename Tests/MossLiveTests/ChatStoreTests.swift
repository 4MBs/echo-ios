@testable import MossLive
import XCTest

@MainActor
final class ChatStoreTests: XCTestCase {
    func testStoreAlwaysKeepsOneConversation() {
        let store = ChatStore(loadPersisted: false)
        let initialID = store.selectedConversationID

        store.delete(initialID)

        XCTAssertEqual(store.conversations.count, 1)
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNotEqual(store.selectedConversationID, initialID)
    }

    func testCreatingConversationDoesNotStackBlankChats() {
        let store = ChatStore(loadPersisted: false)

        store.createConversation(context: .lesson(id: "lesson-1", title: "Mathematik"))

        XCTAssertEqual(store.conversations.count, 1)
        XCTAssertEqual(store.context, .lesson(id: "lesson-1", title: "Mathematik"))
    }

    func testPersistedAttachmentOmitsOriginalUploadData() throws {
        let attachment = ChatStore.Attachment(
            kind: .image,
            fileName: "Tafel.jpg",
            mimeType: "image/jpeg",
            byteCount: 3,
            thumbnailData: Data([1]),
            extractedText: "Satz des Pythagoras",
            uploadData: Data([1, 2, 3])
        )

        let encoded = try JSONEncoder().encode(attachment)
        let decoded = try JSONDecoder().decode(ChatStore.Attachment.self, from: encoded)

        XCTAssertEqual(decoded.thumbnailData, Data([1]))
        XCTAssertEqual(decoded.extractedText, "Satz des Pythagoras")
        XCTAssertNil(decoded.uploadData)
    }
}
