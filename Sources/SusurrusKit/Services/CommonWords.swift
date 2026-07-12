import Foundation

/// High-frequency English words that the transcript corrector must never
/// rewrite via fuzzy matching. Guards against a legitimately spoken common
/// word being "corrected" into a phonetically-similar vocabulary term
/// (e.g. "person" → "Pearson"). Multi-word joins that normalize exactly to
/// a vocabulary term bypass this guard by design.
enum CommonWords {
    static func contains(_ normalizedWord: String) -> Bool {
        top.contains(normalizedWord) || domainStoplist.contains(normalizedWord)
    }

    /// Short, common-English fragments of the seed vocabulary's multi-word
    /// terms (MarkLogic, CoRB, SPARQL, Datavid, Trust Signals). Kept separate
    /// from `top` so the frequency list stays a real frequency list: this is
    /// an explicit, user/domain-specific guard, not a claim about word rank.
    /// Contributors should add their own domain fragments here, never to `top`.
    static let domainStoplist: Set<String> = [
        "mark", "logic", "core", "spark", "vid", "trust", "signal", "signals",
    ]

    /// ~700 most frequent English words (lowercase, alphanumeric-normalized).
    static let top: Set<String> = [
        // Function words
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "i",
        "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
        "this", "but", "his", "by", "from", "they", "we", "say", "her", "she",
        "or", "an", "will", "my", "one", "all", "would", "there", "their", "what",
        "so", "up", "out", "if", "about", "who", "get", "which", "go", "me",
        "while", "where", "why", "before", "between", "during", "against", "under",
        "though", "although", "since", "until", "unless", "whether", "either", "neither",
        "nor", "via", "else", "along", "around", "above", "below", "both", "down", "off",
        "when", "make", "can", "like", "time", "no", "just", "him", "know", "take",
        "people", "into", "year", "your", "good", "some", "could", "them", "see", "other",
        "than", "then", "now", "look", "only", "come", "its", "over", "think", "also",
        "back", "after", "use", "two", "how", "our", "work", "first", "well", "way",
        "even", "new", "want", "because", "any", "these", "give", "day", "most", "us",
        "is", "was", "are", "were", "been", "being", "has", "had", "did", "does",
        "am", "shall", "may", "might", "must", "should", "ought", "need", "dare", "used",
        "im", "ive", "id", "ill", "youre", "youve", "youd", "youll", "hes", "shes",
        "its", "were", "weve", "wed", "well", "theyre", "theyve", "theyd", "theyll", "thats",
        "isnt", "arent", "wasnt", "werent", "hasnt", "havent", "hadnt", "dont", "doesnt", "didnt",
        "wont", "wouldnt", "cant", "couldnt", "shouldnt", "mustnt", "lets", "heres", "theres", "whats",
        // Common nouns
        "man", "woman", "child", "children", "world", "school", "state", "family", "student", "group",
        "country", "problem", "hand", "part", "place", "case", "week", "company", "system", "program",
        "question", "government", "number", "night", "point", "home", "water", "room", "mother", "area",
        "money", "story", "fact", "month", "lot", "right", "study", "book", "eye", "job",
        "word", "business", "issue", "side", "kind", "head", "house", "service", "friend", "father",
        "power", "hour", "game", "line", "end", "member", "law", "car", "city", "community",
        "name", "president", "team", "minute", "idea", "kid", "body", "information", "parent", "face",
        "others", "level", "office", "door", "health", "person", "art", "war", "history", "party",
        "result", "change", "morning", "reason", "research", "girl", "guy", "moment", "air", "teacher",
        "force", "education", "foot", "boy", "age", "policy", "process", "music", "market", "sense",
        "nation", "plan", "college", "interest", "death", "experience", "effect", "class", "control", "care",
        "field", "development", "role", "effort", "rate", "heart", "drug", "show", "leader", "light",
        "voice", "wife", "police", "mind", "price", "report", "decision", "son", "view", "relationship",
        "town", "road", "arm", "difference", "value", "building", "action", "model", "season", "society",
        "tax", "director", "position", "player", "record", "paper", "space", "ground", "form", "event",
        "matter", "center", "couple", "site", "project", "activity", "star", "table", "court", "american",
        "oil", "situation", "cost", "industry", "figure", "street", "image", "phone", "data", "picture",
        "practice", "piece", "land", "product", "doctor", "wall", "patient", "worker", "news", "test",
        "movie", "north", "love", "support", "technology", "step", "baby", "computer", "type", "attention",
        "film", "tree", "source", "subject", "rule", "card", "feeling", "thing", "food", "quality",
        "list", "email", "note", "meeting", "call", "message", "update", "task", "item", "detail",
        "review", "version", "release", "feature", "user", "customer", "client", "account", "order", "budget",
        "design", "code", "file", "page", "screen", "button", "link", "text", "search", "share",
        // Common verbs
        "find", "tell", "ask", "seem", "feel", "try", "leave", "put", "mean", "keep",
        "let", "begin", "help", "talk", "turn", "start", "hear", "play", "run", "move",
        "live", "believe", "hold", "bring", "happen", "write", "provide", "sit", "stand", "lose",
        "pay", "meet", "include", "continue", "set", "learn", "lead", "leads", "understand", "watch",
        "follow", "stop", "create", "speak", "read", "allow", "add", "spend", "grow", "open",
        "walk", "win", "offer", "remember", "consider", "appear", "buy", "wait", "serve", "die",
        "send", "expect", "build", "stay", "fall", "cut", "reach", "kill", "remain", "suggest",
        "raise", "pass", "sell", "require", "decide", "pull", "return", "explain", "hope", "develop",
        "carry", "break", "receive", "agree", "increase", "check", "cover", "argue", "close", "fix",
        "wonder", "thank", "worry", "wish", "accept", "listen", "finish", "improve", "discuss",
        "eat", "drink", "sleep", "drive", "wear", "choose", "teach", "throw", "catch", "draw",
        "done", "gone", "went", "made", "said", "told", "took", "came", "knew", "got",
        "saw", "found", "gave", "thought", "looked", "used", "worked", "called", "asked", "needed",
        "making", "going", "getting", "looking", "working", "trying", "using", "doing", "saying", "coming",
        // Common adjectives/adverbs
        "great", "little", "own", "old", "big", "high", "different", "small", "large", "next",
        "early", "young", "important", "few", "public", "bad", "same", "able", "last", "long",
        "better", "best", "sure", "free", "low", "late", "hard", "major", "real", "possible",
        "whole", "single", "true", "main", "easy", "clear", "full", "special", "certain", "personal",
        "red", "difficult", "available", "likely", "short", "recent", "strong", "human", "local",
        "actually", "probably", "really", "very", "still", "too", "much", "many", "more", "here",
        "again", "never", "always", "often", "however", "almost", "later", "far", "together", "once",
        "please", "maybe", "quite", "rather", "already", "yet", "soon", "today", "tomorrow", "yesterday",
        "quickly", "simply", "finally", "currently", "basically", "definitely", "exactly", "obviously", "certainly", "totally",
        "something", "anything", "everything", "nothing", "someone", "anyone", "everyone", "nobody", "somewhere", "anywhere",
        "okay", "yeah", "yes", "hello", "hi", "thanks", "sorry", "cool", "fine",
        // Numbers, time, misc
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "twenty", "thirty", "forty", "fifty", "hundred", "thousand", "million",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march",
        "april", "june", "july", "august", "september", "october", "november", "december", "spring", "summer",
        "second", "third", "half", "quarter", "percent", "billion", "several", "both", "each",
    ]
}
