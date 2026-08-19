enum RockchipDigestValidation {
  static func isCanonicalSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
      }
  }
}
