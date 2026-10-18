import Foundation

/// Recent macOS versions often leave `message.text` NULL and store the body only in
/// `attributedBody`, an NSAttributedString archived in the legacy typedstream format.
/// Only the string payload is needed, so this reads it directly instead of unarchiving
/// objects from a database written by other people's messages.
enum AttributedBodyDecoder {
  private static let header = Array("streamtyped".utf8)
  /// NSString is the text's class, or the superclass that follows NSMutableString.
  private static let stringClass = Array("NSString".utf8)
  private static let maximumLength = 1_048_576

  static func text(from data: Data) -> String? {
    let bytes = [UInt8](data)
    guard bytes.count > header.count + 2, Array(bytes[2..<(2 + header.count)]) == header else { return nil }
    // The first string class in the archive belongs to the attributed string's text.
    guard let classEnd = firstEnd(of: stringClass, in: bytes) else { return nil }
    // After the class name: version and type markers, then '+' introduces the UTF-8 bytes.
    guard let plus = (classEnd..<min(bytes.count, classEnd + 12)).first(where: { bytes[$0] == 0x2B }) else { return nil }
    var index = plus + 1
    guard let length = readLength(bytes, at: &index), length <= maximumLength,
          index + length <= bytes.count else { return nil }
    return String(bytes: bytes[index..<(index + length)], encoding: .utf8)
  }

  /// Typedstream integers: a byte below 0x80 is the value; 0x81 and 0x82 introduce
  /// little-endian 16- and 32-bit values.
  private static func readLength(_ bytes: [UInt8], at index: inout Int) -> Int? {
    guard index < bytes.count else { return nil }
    let marker = bytes[index]
    index += 1
    switch marker {
    case 0..<0x80:
      return Int(marker)
    case 0x81:
      guard index + 2 <= bytes.count else { return nil }
      defer { index += 2 }
      return Int(bytes[index]) | Int(bytes[index + 1]) << 8
    case 0x82:
      guard index + 4 <= bytes.count else { return nil }
      defer { index += 4 }
      return (0..<4).reduce(0) { $0 | Int(bytes[index + $1]) << (8 * $1) }
    default:
      return nil
    }
  }

  private static func firstEnd(of needle: [UInt8], in bytes: [UInt8]) -> Int? {
    guard bytes.count >= needle.count else { return nil }
    for start in 0...(bytes.count - needle.count) where bytes[start] == needle[0] {
      if bytes[start..<(start + needle.count)].elementsEqual(needle) { return start + needle.count }
    }
    return nil
  }
}
