import ArkDeckWorkflows
import Foundation

enum FlashBundleArtifactImportError: Error, Equatable, CustomStringConvertible {
  case invalidBundle(String)

  var description: String {
    switch self {
    case .invalidBundle(let detail):
      return "flash bundle is not a usable DAYU200 images archive: \(detail)"
    }
  }
}

struct FlashBundleImportValidation: Sendable, Equatable {
  let byteCount: Int
  let sha256: String
}

struct FlashBundleImportPolicy: Sendable {
  struct Candidate: Sendable {
    /// Left nil by the production policy: an archive is judged by reading it,
    /// not by being recognised before it is read. Tests still pin exact
    /// expectations, and a candidate that states them keeps being matched on
    /// them.
    let expectedByteCount: Int?
    let expectedSHA256: String?
    let validate: @Sendable (URL) throws -> FlashBundleImportValidation
  }

  let candidates: [Candidate]

  init(
    expectedByteCount: Int,
    expectedSHA256: String,
    validate: @escaping @Sendable (URL) throws -> FlashBundleImportValidation
  ) {
    candidates = [
      Candidate(
        expectedByteCount: expectedByteCount,
        expectedSHA256: expectedSHA256,
        validate: validate)
    ]
  }

  init(candidates: [Candidate]) {
    precondition(!candidates.isEmpty)
    self.candidates = candidates
  }

  func candidate(byteCount: Int, sha256: String) -> Candidate? {
    candidates.first {
      ($0.expectedByteCount ?? byteCount) == byteCount
        && ($0.expectedSHA256 ?? sha256) == sha256
    }
  }

  /// Accepts any archive that reads as a DAYU200 images bundle.
  ///
  /// It used to accept only the two builds enumerated in the product, matched
  /// by digest before anything was read. A daily published after the last
  /// release was refused with nineteen hash mismatches while fitting the board
  /// perfectly — measured against the 7.0.0.37 build on 2026-08-05.
  ///
  /// What replaces that is not "no checking". The archive is decompressed and
  /// hashed here, its partition table is parsed, its runtime version is read
  /// out of the system image, and it must fit this board structurally: every
  /// mapped partition has an image, the table declares nothing unknown. What
  /// is gone is the requirement that somebody had already met this build.
  static let production: FlashBundleImportPolicy = {
    FlashBundleImportPolicy(candidates: [
      Candidate(expectedByteCount: nil, expectedSHA256: nil) { url in
        let board = RockchipFlashProfile.dayu200
        let summary: GzipTarArchiveSummary
        do {
          summary = try GzipTarArchiveReader.summarize(
            fileAt: url,
            derivation: RockchipImageArchiveIntrospection.derivationRequest(board: board))
        } catch {
          throw FlashBundleArtifactImportError.invalidBundle("\(error)")
        }
        do {
          let build = try RockchipImageArchiveIntrospection.describe(
            summary: summary, board: board)
          _ = try board.forBuild(build)
          return FlashBundleImportValidation(
            byteCount: Int(summary.archiveSizeBytes),
            sha256: summary.archiveSHA256)
        } catch {
          throw FlashBundleArtifactImportError.invalidBundle("\(error)")
        }
      }
    ])
  }()
}
