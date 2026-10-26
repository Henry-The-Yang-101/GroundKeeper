enum QueueProcessingScope {
    case captures, suggestions, all

    var importsCaptures: Bool { self != .suggestions }
    var suggestsCategories: Bool { self != .captures }
}
