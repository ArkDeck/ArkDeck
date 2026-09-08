// Compile together with the unmodified protected-main PortableCanonicalJSON.swift:
// swiftc -package-name ArkDeck -parse-as-library <source> <this-file> -o <probe>
// Run <probe> <source-path> and retain stdout as swift-number-boundaries.json.
// This probes that exact function, including its existing formatting limits;
// it makes no claim of complete RFC 8785 conformance or hardware validation.

import CryptoKit
import Foundation

// Only needed to typecheck the other functions in the source file. The probe
// invokes serialize(Double) directly and never constructs this enum.
package enum JSONValue {
    case null, bool(Bool), integer(Int64), unsignedInteger(UInt64), number(Double)
    case string(String), array([JSONValue]), object([String: JSONValue])
}

@main
enum SwiftNumberBoundaries {
    static func main() throws {
        let source = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let cases: [(String, Double)] = [
            ("positiveZero", 0), ("negativeZero", -0.0),
            ("oneTenth", 0.1), ("oneHalf", 0.5), ("negativeHalf", -0.5),
            ("integralDouble", 1.0), ("noninteger", 1.23456789),
            ("oneEMinus3", 1e-3), ("oneEMinus4", 1e-4),
            ("oneEMinus5", 1e-5), ("oneEMinus6", 1e-6), ("oneEMinus7", 1e-7),
            ("smallNoninteger", 1.23456789e-5), ("oneEMinus20", 1e-20),
            ("oneE15", 1e15), ("exactIntegerLimit", 9_007_199_254_740_991),
            ("aboveExactIntegerLimit", 9_007_199_254_740_992),
            ("nextRepresentableInteger", 9_007_199_254_740_994),
            ("negativeExactIntegerLimit", -9_007_199_254_740_991),
            ("negativeAboveExactIntegerLimit", -9_007_199_254_740_992),
            ("oneE19", 1e19), ("oneE20", 1e20), ("oneE21", 1e21),
            ("largeNonPowerOfTen", 1.2345678901234567e19),
            ("positiveInt64Boundary", Double(Int64.max)),
            ("negativeInt64Boundary", Double(Int64.min)),
            ("negativeBeyondInt64", Double(Int64.min).nextDown),
            ("pi", Double.pi),
            ("leastPositiveDouble", Double.leastNonzeroMagnitude),
            ("greatestFiniteDouble", Double.greatestFiniteMagnitude),
            ("positiveInfinity", .infinity), ("negativeInfinity", -.infinity), ("nan", .nan),
        ]
        let vectors: [[String: Any]] = cases.map { name, number in
            var row: [String: Any] = [
                "name": name,
                "binary64Bits": String(format: "%016llx", number.bitPattern),
            ]
            do {
                row["canonical"] = try PortableCanonicalJSON.serialize(number)
                row["outcome"] = "encoded"
            } catch PortableCanonicalJSON.Failure.integerBeyondExactRange {
                row["outcome"] = "integerBeyondExactRange"
            } catch PortableCanonicalJSON.Failure.nonFiniteNumber {
                row["outcome"] = "nonFiniteNumber"
            } catch {
                fatalError("unexpected encoding refusal: \(error)")
            }
            return row
        }
        let output: [String: Any] = [
            "sourceCommit": "a076ca31ef97ef4285981af053d07b7fe0f052bd",
            "sourcePath": "Packages/ArkDeckKit/Sources/ArkDeckCore/PortableCanonicalJSON.swift",
            "sourceSHA256": SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(),
            "function": "PortableCanonicalJSON.serialize(Double)",
            "validationClass": "nativeSwiftPureEncoding",
            "vectors": vectors,
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(
            withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}
