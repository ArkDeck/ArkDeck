import Foundation

/// The frames a screen sequence brought back.
///
/// The runtime publishes one archive rather than N artifacts because a receive
/// lands one file. Reading it here rather than shelling out to `tar` keeps the
/// workspace from spawning anything: the format is fixed-position headers, so
/// parsing it is cheaper than the process would be, and a malformed archive
/// becomes a typed refusal instead of an exit code.
public enum DeviceFrameArchive {
  public struct Frame: Sendable, Equatable {
    /// The name the provider wrote, which is the capture index zero-padded.
    public let name: String
    public let bytes: Data
  }

  public enum ArchiveUnreadable: Error, Equatable {
    case notATarArchive
    case truncated(afterFrames: Int)
    case entryTooLarge(name: String)
    /// A name that would escape the archive, or that this provider did not
    /// write. Frames are named by index, so anything else is not a frame.
    case unexpectedEntry(name: String)
  }

  private static let blockSize = 512
  private static let maximumEntryBytes = 32 * 1024 * 1024

  /// Ordered by name, which is the capture order: the provider zero-pads the
  /// index precisely so the archive's own ordering carries it.
  public static func frames(in archive: Data) throws -> [Frame] {
    guard archive.count >= blockSize else { throw ArchiveUnreadable.notATarArchive }
    var frames: [Frame] = []
    var offset = 0
    var sawAnyHeader = false
    // A tar ends with zero blocks. Running out of bytes without reaching them
    // means the archive was cut short, and the frames read so far are however
    // many survived - not a complete run that happened to be shorter.
    var reachedTheEnd = false

    while offset + blockSize <= archive.count {
      let header = archive[
        archive.startIndex + offset..<archive.startIndex + offset + blockSize]
      // Two zero blocks end the archive; one is enough to stop reading.
      if header.allSatisfy({ $0 == 0 }) {
        reachedTheEnd = true
        break
      }
      guard field(header, at: 257, length: 5) == "ustar" else {
        throw sawAnyHeader
          ? ArchiveUnreadable.truncated(afterFrames: frames.count)
          : ArchiveUnreadable.notATarArchive
      }
      sawAnyHeader = true

      let name = field(header, at: 0, length: 100)
      guard let size = octal(field(header, at: 124, length: 12)) else {
        throw ArchiveUnreadable.truncated(afterFrames: frames.count)
      }
      guard size <= maximumEntryBytes else {
        throw ArchiveUnreadable.entryTooLarge(name: name)
      }
      let typeFlag = byte(header, at: 156)
      offset += blockSize

      // '0' and NUL both mean a regular file; anything else (directories, the
      // "./" entry `tar -C . ` writes) carries no frame.
      if typeFlag == UInt8(ascii: "0") || typeFlag == 0 {
        guard offset + size <= archive.count else {
          throw ArchiveUnreadable.truncated(afterFrames: frames.count)
        }
        let leaf = (name as NSString).lastPathComponent
        if isFrameName(leaf) {
          guard leaf == name || name == "./" + leaf else {
            throw ArchiveUnreadable.unexpectedEntry(name: name)
          }
          frames.append(
            Frame(
              name: leaf,
              bytes: archive[
                archive.startIndex + offset..<archive.startIndex + offset + size]))
        }
      }
      // Entries are padded up to the next block boundary.
      offset += (size + blockSize - 1) / blockSize * blockSize
    }

    guard sawAnyHeader else { throw ArchiveUnreadable.notATarArchive }
    guard reachedTheEnd else { throw ArchiveUnreadable.truncated(afterFrames: frames.count) }
    return frames.sorted { $0.name < $1.name }
  }

  /// `NNNN.png` or `NNNN.jpeg`, and nothing else. The provider names frames by
  /// index, so a name it did not write is not a frame this can compose.
  static func isFrameName(_ name: String) -> Bool {
    let parts = name.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 4,
      parts[0].allSatisfy(\.isNumber), ["png", "jpeg"].contains(String(parts[1]))
    else { return false }
    return true
  }

  private static func byte(_ block: Data, at index: Int) -> UInt8 {
    block[block.startIndex + index]
  }

  private static func field(_ block: Data, at index: Int, length: Int) -> String {
    let slice = block[block.startIndex + index..<block.startIndex + index + length]
    let trimmed = slice.prefix { $0 != 0 && $0 != UInt8(ascii: " ") }
    return String(decoding: trimmed, as: UTF8.self)
  }

  private static func octal(_ text: String) -> Int? {
    guard !text.isEmpty, text.allSatisfy({ ("0"..."7").contains($0) }) else { return nil }
    return Int(text, radix: 8)
  }
}
