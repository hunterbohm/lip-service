/// An array decoded element by element, so an element that does not read drops only itself.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) { elements.append(element) } else { _ = try container.decode(Skipped.self) }
        }
    }
}

/// A string-keyed object decoded value by value, so a value that does not read drops only its key.
struct LossyValues<Value: Decodable>: Decodable {
    var values: [String: Value] = [:]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        for key in container.allKeys {
            if let value = try? container.decode(Value.self, forKey: key) { values[key.stringValue] = value }
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Reads any value and keeps nothing, to step past an element that did not decode.
private struct Skipped: Decodable {
    init(from decoder: any Decoder) throws {}
}
