import Foundation

/// Categories for vocabulary entries. Each category provides context
/// for how the LLM should treat the term during cleanup.
public enum VocabularyCategory: String, Codable, CaseIterable, Sendable {
    case person
    case place
    case project
    case product
    case technical
    case acronym
    case custom

    /// Human-readable label for UI display.
    public var displayName: String {
        switch self {
        case .person: return "Person"
        case .place: return "Place"
        case .project: return "Project"
        case .product: return "Product"
        case .technical: return "Technical"
        case .acronym: return "Acronym"
        case .custom: return "Custom"
        }
    }

    /// SF Symbol name for UI display.
    public var systemImage: String {
        switch self {
        case .person: return "person"
        case .place: return "mappin.and.ellipse"
        case .project: return "folder"
        case .product: return "shippingbox"
        case .technical: return "gearshape"
        case .acronym: return "textformat.abc"
        case .custom: return "tag"
        }
    }

    /// Instructions for the LLM about how to treat terms in this category.
    public var llmInstruction: String {
        switch self {
        case .person: return "is a person's name — always capitalize"
        case .place: return "is a place name — always capitalize"
        case .project: return "is a project codename — treat as proper noun"
        case .product: return "is a product name — always capitalize, never translate"
        case .technical: return "is a technical term — preserve exact spelling and capitalization"
        case .acronym: return "is an acronym — always uppercase"
        case .custom: return "is a custom term — preserve exact spelling"
        }
    }
}
