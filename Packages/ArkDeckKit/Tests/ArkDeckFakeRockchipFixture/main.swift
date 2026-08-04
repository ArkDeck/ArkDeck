import Darwin
import Foundation

private let arguments = Array(CommandLine.arguments.dropFirst())

private func fail(_ message: String, code: Int32 = 64) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

guard let operation = arguments.first else { fail("missing operation") }
switch operation {
case "ld":
  guard arguments.count == 1 else { fail("ld takes no arguments") }
  print("DevNo=1\tVid=0x2207,Pid=0x350a,LocationID=42\tLoader")
case "ppt":
  guard arguments.count == 1 else { fail("ppt takes no arguments") }
  print("**********Partition Info(GPT)**********")
  print("NO  LBA       Name")
  let rows = [
    "00  00002000  uboot", "01  00004000  misc", "02  00006000  bootctrl",
    "03  00007000  resource", "04  0000A000  boot_linux", "05  0003A000  ramdisk",
    "06  0003C000  system", "07  0043C000  vendor", "08  0063C000  sys-prod",
    "09  00655000  chip-prod", "10  0066E000  updater", "11  0067E000  eng_system",
    "12  00686000  eng_chipset", "13  0069E000  chip_ckm", "14  01308000  userdata",
  ]
  for row in rows {
    print(row)
  }
case "wl", "wlx":
  guard arguments.count == 3 else {
    fail("\(operation) requires an address argument and a descriptor path")
  }
  if operation == "wl" {
    guard arguments[1].range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
      arguments[1] == "0" || arguments[1].first != "0"
    else {
      fail("invalid begin sector")
    }
  } else {
    // `wlx` is name-addressed: the name must resolve against the same pinned
    // DAYU200 table the `ppt` output above serves.
    let partitionNames: Set<String> = [
      "uboot", "misc", "bootctrl", "resource", "boot_linux", "ramdisk",
      "system", "vendor", "sys-prod", "chip-prod", "updater", "eng_system",
      "eng_chipset", "chip_ckm", "userdata",
    ]
    guard partitionNames.contains(arguments[1]) else {
      fail("unknown partition name: \(arguments[1])", code: 66)
    }
  }
  var metadata = stat()
  guard lstat(arguments[2], &metadata) == 0,
    metadata.st_mode & S_IFMT == S_IFREG,
    metadata.st_size > 0
  else { fail("image descriptor is not a nonempty regular file", code: 65) }
  let descriptor = Darwin.open(arguments[2], O_RDONLY | O_NOFOLLOW)
  guard descriptor >= 0 else { fail("image descriptor cannot be opened", code: 65) }
  defer { Darwin.close(descriptor) }
  var byte: UInt8 = 0
  guard Darwin.read(descriptor, &byte, 1) == 1 else {
    fail("image descriptor contains no readable byte", code: 65)
  }
  print("Write LBA from file (100%)")
case "rl":
  guard arguments.count == 4 else { fail("rl requires begin sector, count and output path") }
  guard let begin = Int64(arguments[1]), begin >= 0,
    let count = Int64(arguments[2]), count > 0, count <= 1 << 20
  else { fail("invalid rl range") }
  // The medium probe reads the primary header and the backup it names, so the
  // fake carries the same DAYU200 geometry the pinned table describes.
  var payload = Data(repeating: 0, count: Int(count) * 512)
  func writeHeader(at offset: Int, myLBA: Int64, alternateLBA: Int64) {
    payload.replaceSubrange(offset..<(offset + 8), with: Array("EFI PART".utf8))
    for (index, value) in [(24, myLBA), (32, alternateLBA), (40, Int64(34)),
      (48, Int64(61_071_326))]
    {
      var raw = UInt64(bitPattern: value)
      for byte in 0..<8 {
        payload[offset + index + byte] = UInt8(raw & 0xFF)
        raw >>= 8
      }
    }
  }
  if begin <= 1 && begin + count > 1 {
    writeHeader(at: Int(1 - begin) * 512, myLBA: 1, alternateLBA: 61_071_359)
  }
  if begin <= 61_071_359 && begin + count > 61_071_359 {
    writeHeader(
      at: Int(61_071_359 - begin) * 512, myLBA: 61_071_359, alternateLBA: 1)
  }
  guard FileManager.default.createFile(atPath: arguments[3], contents: payload) else {
    fail("cannot write rl output", code: 65)
  }
  print("Read LBA to file (100%)")
case "rd":
  guard arguments.count == 1 else { fail("rd takes no arguments") }
  print("Reset Device OK.")
default:
  fail("unsupported operation: \(operation)")
}
