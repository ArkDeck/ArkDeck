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
case "wlx":
  guard arguments.count == 3 else { fail("wlx requires partition and descriptor path") }
  guard arguments[1].range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil else {
    fail("invalid partition")
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
  if arguments[1] == "critical_hold" { usleep(400_000) }
  print("Write LBA from file (100%)")
case "rd":
  guard arguments.count == 1 else { fail("rd takes no arguments") }
  print("Reset Device OK.")
default:
  fail("unsupported operation: \(operation)")
}
