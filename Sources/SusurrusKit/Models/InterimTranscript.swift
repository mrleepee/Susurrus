import Foundation

/// Represents a snapshot of interim transcription text during a streaming session.
/// Confirmed text has been committed by the model; unconfirmed text is still in-flight.
public struct InterimTranscript: Sendable, Equatable {
    /// Text the model has committed to (displayed in primary color).
    public let confirmed: String

    /// Text currently in-flight / unconfirmed (displayed in secondary color).
    public let unconfirmed: String

    /// True when the stream has stopped and this is the final transcript.
    public let isFinal: Bool

    public init(confirmed: String, unconfirmed: String, isFinal: Bool) {
        self.confirmed = confirmed
        self.unconfirmed = unconfirmed
        self.isFinal = isFinal
    }

    /// Convenience: full transcript combining confirmed and unconfirmed text.
    public var fullText: String {
        confirmed + unconfirmed
    }
}
