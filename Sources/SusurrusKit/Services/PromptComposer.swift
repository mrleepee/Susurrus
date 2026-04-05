import Foundation

/// Assembles the full LLM system prompt from multiple contributing sections.
///
/// Each feature (vocabulary categories, correction pairs, notebook context)
/// contributes a section. Empty sections are omitted to keep the prompt clean.
public struct PromptComposer: Sendable {

    public init() {}

    /// Compose the full system prompt for LLM cleanup.
    /// - Parameters:
    ///   - base: The user's base prompt from preferences (always first).
    ///   - vocabularyContext: Category-annotated vocabulary terms for LLM guidance.
    ///   - correctionExamples: Few-shot correction pairs from edit-driven learning.
    ///   - notebookContext: Recent notebook entries as domain context.
    /// - Returns: The assembled system prompt.
    public func compose(
        base: String,
        vocabularyContext: String = "",
        correctionExamples: String = "",
        notebookContext: String = ""
    ) -> String {
        var sections = [base.trimmingCharacters(in: .whitespacesAndNewlines)]

        let vocab = vocabularyContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            sections.append("Vocabulary guidance:\n\(vocab)")
        }

        let corrections = correctionExamples.trimmingCharacters(in: .whitespacesAndNewlines)
        if !corrections.isEmpty {
            sections.append("Examples of previous corrections by this user:\n\(corrections)")
        }

        let notebook = notebookContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notebook.isEmpty {
            sections.append("Project context (recent entries):\n\(notebook)")
        }

        return sections.joined(separator: "\n\n")
    }
}
