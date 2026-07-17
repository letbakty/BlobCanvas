import Foundation
import CoreGraphics
import SwiftData

/// SwiftData record for one drawing.
///
/// Deliberately *not* relational: the entire stroke history lives in a single
/// compressed binary blob (`compressedData`). SwiftData only ever sees one row
/// per drawing, so fetches, saves, and iCloud sync stay O(1) regardless of
/// stroke count. `.externalStorage` lets SwiftData spill large blobs to a
/// sidecar file automatically, keeping the store itself tiny.
@Model
public final class Drawing {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var modifiedAt: Date

    /// The full `DrawingSession`, encoded by `DrawingBlobCodec` (LZFSE).
    @Attribute(.externalStorage) public var compressedData: Data

    /// Small PNG preview for gallery lists — avoids decoding+rendering the whole
    /// drawing just to show a cell. Spilled to external storage like the blob.
    @Attribute(.externalStorage) public var thumbnailData: Data?

    /// Monotonic token guarding async saves (B1): each `save` call claims the
    /// next token before encoding off-actor; when it finishes it only writes back
    /// if it is still the latest. Prevents a slow older encode from clobbering a
    /// newer one when strokes arrive faster than LZFSE compresses. Not persisted.
    @Transient private var saveToken = 0

    public init(
        id: UUID = UUID(),
        title: String = "Untitled",
        session: DrawingSession = DrawingSession()
    ) {
        self.id = id
        self.title = title
        let now = Date.now
        self.createdAt = now
        self.modifiedAt = now
        self.compressedData = session.serialized()
        self.thumbnailData = nil
    }
}

// MARK: - Session bridging

public extension Drawing {
    /// Decodes the blob into a working in-memory session. Do this once when
    /// opening the drawing; all editing happens on the returned value.
    func makeSession() throws -> DrawingSession {
        try DrawingSession(serialized: compressedData)
    }

    /// Re-encodes the session into the blob synchronously. Fine for small
    /// drawings on a debounced timer; for large ones prefer ``save(_:)`` async.
    func saveSync(_ session: DrawingSession) {
        compressedData = session.serialized()
        modifiedAt = .now
    }

    /// Encodes the session off the main actor (LZFSE compression can hitch on
    /// large drawings), then assigns the blob back on the main actor. Call this
    /// from your debounced auto-save; follow it with `try context.save()`.
    ///
    /// `DrawingSession` is a `Sendable` value type, so the copy handed to the
    /// background task is fully isolated from further edits.
    @MainActor
    func save(_ session: DrawingSession) async {
        saveToken &+= 1
        let token = saveToken
        let blob = await Task.detached(priority: .utility) {
            session.serialized()
        }.value
        // Более новый save уже записался — не откатываем его старым блобом (B1).
        guard token == saveToken else { return }
        compressedData = blob
        modifiedAt = .now
    }

    /// Encodes the blob *and* regenerates the thumbnail off the main actor, then
    /// assigns both back. Use when you also want the gallery preview refreshed.
    @MainActor
    func save(_ session: DrawingSession, thumbnailMaxDimension: CGFloat) async {
        saveToken &+= 1
        let token = saveToken
        let (blob, thumb) = await Task.detached(priority: .utility) {
            (session.serialized(),
             DrawingExporter.thumbnailPNG(session, maxDimension: thumbnailMaxDimension))
        }.value
        guard token == saveToken else { return }  // B1: newest save wins
        compressedData = blob
        thumbnailData = thumb
        modifiedAt = .now
    }
}

public extension DrawingSession {
    /// Flat-binary, LZFSE-compressed representation. See `DrawingBlobCodec`.
    func serialized() -> Data {
        DrawingBlobCodec.encode(self)
    }

    init(serialized data: Data) throws {
        self = try DrawingBlobCodec.decode(data)
    }
}
