#![cfg(target_os = "macos")]
use arkdeck_hoststore::tool_macho::{self, Slice, USB_LOAD_NAME};
use std::{
    fs::{File, OpenOptions},
    io::{Seek, SeekFrom, Write},
    path::PathBuf,
};
struct Input {
    file: File,
    path: PathBuf,
}
impl Input {
    fn new(bytes: &[u8]) -> Self {
        let nonce = arkdeck_platform::random_bytes::<16>()
            .unwrap()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        let path = PathBuf::from(format!("/private/tmp/arkdeck-macho-{nonce}"));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        file.write_all(bytes).unwrap();
        drop(file);
        Self {
            file: File::open(&path).unwrap(),
            path,
        }
    }
}
impl Drop for Input {
    fn drop(&mut self) {
        std::fs::remove_file(&self.path).unwrap();
    }
}
fn word(bytes: &mut [u8], offset: usize, value: u64, width: usize, little: bool) {
    let raw = if little {
        value.to_le_bytes()
    } else {
        value.to_be_bytes()
    };
    bytes[offset..offset + width].copy_from_slice(if little {
        &raw[..width]
    } else {
        &raw[8 - width..]
    });
}
fn command(kind: u32, text: &[u8], header: usize, wide: bool, little: bool) -> Vec<u8> {
    let alignment = if wide { 8 } else { 4 };
    let length = (header + text.len() + 1).div_ceil(alignment) * alignment;
    let mut data = vec![0; length];
    word(&mut data, 0, kind.into(), 4, little);
    word(&mut data, 4, length as u64, 4, little);
    word(&mut data, 8, header as u64, 4, little);
    data[header..header + text.len()].copy_from_slice(text);
    data
}
fn thin(wide: bool, little: bool, file_type: u64, commands: &[Vec<u8>]) -> Vec<u8> {
    let header = if wide { 32 } else { 28 };
    let command_size = commands.iter().map(Vec::len).sum::<usize>();
    let mut data = vec![0; header];
    word(
        &mut data,
        0,
        if wide { 0xfeedfacf } else { 0xfeedface },
        4,
        little,
    );
    word(&mut data, 12, file_type, 4, little);
    word(&mut data, 16, commands.len() as u64, 4, little);
    word(&mut data, 20, command_size as u64, 4, little);
    for command in commands {
        data.extend(command);
    }
    data
}
fn executable() -> Vec<u8> {
    thin(
        true,
        true,
        2,
        &[
            command(0xc, USB_LOAD_NAME.as_bytes(), 24, true, true),
            command(0x8000001c, b"@loader_path/.", 12, true, true),
        ],
    )
}
fn inspect(bytes: &[u8]) -> Vec<Slice> {
    tool_macho::inspect(&Input::new(bytes).file).unwrap()
}
fn refused(bytes: &[u8]) {
    let error = tool_macho::inspect(&Input::new(bytes).file).unwrap_err();
    assert_eq!(error.code, "invalidInput");
    assert_eq!(
        error.message,
        "host tool has malformed or unbounded Mach-O load commands"
    );
}
fn fat(wide: bool, little: bool, slices: &[Vec<u8>]) -> Vec<u8> {
    let stride = if wide { 32 } else { 20 };
    let mut data = vec![0; 8 + stride * slices.len()];
    word(
        &mut data,
        0,
        if wide { 0xcafebabf } else { 0xcafebabe },
        4,
        little,
    );
    word(&mut data, 4, slices.len() as u64, 4, little);
    let mut start = data.len();
    for (i, slice) in slices.iter().enumerate() {
        word(
            &mut data,
            8 + i * stride + 8,
            start as u64,
            if wide { 8 } else { 4 },
            little,
        );
        word(
            &mut data,
            8 + i * stride + if wide { 16 } else { 12 },
            slice.len() as u64,
            if wide { 8 } else { 4 },
            little,
        );
        start += slice.len();
    }
    for slice in slices {
        data.extend(slice);
    }
    data
}
#[test]
fn current_swift_layout_and_all_thin_endians_preserve_library_closure() {
    for wide in [false, true] {
        for little in [false, true] {
            for kind in [0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023] {
                let slices = inspect(&thin(
                    wide,
                    little,
                    2,
                    &[
                        command(kind, USB_LOAD_NAME.as_bytes(), 24, wide, little),
                        command(0x8000001c, b"@loader_path/.", 12, wide, little),
                    ],
                ));
                assert_eq!(
                    slices,
                    vec![Slice {
                        file_type: 2,
                        libraries: vec![USB_LOAD_NAME.into()],
                        rpaths: vec!["@loader_path/.".into()],
                        has_environment: false
                    }]
                );
                assert!(tool_macho::needs_usb(&slices));
                assert!(tool_macho::relocatable(&slices, false));
                assert!(!tool_macho::relocatable(&slices, true));
            }
        }
    }
}
#[test]
fn dependency_paths_and_first_rpath_use_the_existing_closed_policy() {
    for path in [
        "/usr/lib/libSystem.B.dylib",
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
        "/usr/lib//nested/lib.dylib",
    ] {
        let slices = inspect(&thin(
            true,
            true,
            6,
            &[command(0xc, path.as_bytes(), 24, true, true)],
        ));
        assert!(!tool_macho::needs_usb(&slices));
        assert!(tool_macho::relocatable(&slices, true));
    }
    for path in [
        "@rpath/other.dylib",
        "@loader_path/libusb_shared.dylib",
        "/tmp/lib.dylib",
        "/usr/lib/../../tmp/other.dylib",
        "/usr/lib/./lib.dylib",
        "/System/Library/Frameworks/../lib.dylib",
        "/usr/library/lib.dylib",
        USB_LOAD_NAME,
    ] {
        let slices = inspect(&thin(
            true,
            true,
            6,
            &[command(0xc, path.as_bytes(), 24, true, true)],
        ));
        assert!(!tool_macho::relocatable(&slices, true), "{path}");
    }
    for rpaths in [
        vec![],
        vec!["/tmp/caller"],
        vec!["/tmp/caller", "@loader_path/."],
    ] {
        let mut commands = vec![command(0xc, USB_LOAD_NAME.as_bytes(), 24, true, true)];
        commands.extend(
            rpaths
                .into_iter()
                .map(|p| command(0x8000001c, p.as_bytes(), 12, true, true)),
        );
        assert!(!tool_macho::relocatable(
            &inspect(&thin(true, true, 2, &commands)),
            false
        ));
    }
    // Preserve the first-rpath rule; the Swift parser does not reject later rpaths.
    let commands = vec![
        command(0xc, USB_LOAD_NAME.as_bytes(), 24, true, true),
        command(0x8000001c, b"@loader_path/.", 12, true, true),
        command(0x8000001c, b"/later/path", 12, true, true),
    ];
    assert!(tool_macho::relocatable(
        &inspect(&thin(true, true, 2, &commands)),
        false
    ));
    let mut environment = vec![0; 8];
    word(&mut environment, 0, 0x27, 4, true);
    word(&mut environment, 4, 8, 4, true);
    let slices = inspect(&thin(true, true, 2, &[environment]));
    assert!(slices[0].has_environment);
    assert!(!tool_macho::relocatable(&slices, false));
    assert!(!tool_macho::relocatable(&[], false));
}
#[test]
fn malformed_commands_strings_and_size_boundaries_are_rejected() {
    let valid = executable();
    for length in 0..valid.len() {
        refused(&valid[..length]);
    }
    for (offset, value) in [
        (0, 0),
        (16, 0),
        (16, 4097),
        (20, u32::MAX.into()),
        (36, 0),
        (36, 9),
        (40, u32::MAX.into()),
        (40, 8),
    ] {
        let mut bytes = valid.clone();
        word(&mut bytes, offset, value, 4, true);
        refused(&bytes);
    }
    let mut extra = valid.clone();
    extra.extend([0; 8]);
    word(&mut extra, 20, (valid.len() - 32 + 8) as u64, 4, true);
    refused(&extra);
    for text in [
        vec![],
        vec![b'a', 0x7f],
        vec![b'a', b'\n'],
        vec![0xff],
        vec![b'a'; 4097],
    ] {
        refused(&thin(true, true, 2, &[command(0xc, &text, 24, true, true)]));
    }
    assert_eq!(
        inspect(&thin(
            true,
            true,
            2,
            &[command(0xc, &vec![b'a'; 4096], 24, true, true)]
        ))[0]
            .libraries[0]
            .len(),
        4096
    );
    let mut missing_nul = command(0xc, b"abc", 24, true, true);
    missing_nul[24..].fill(b'a');
    refused(&thin(true, true, 2, &[missing_nul]));
    let mut opaque = vec![0; 8];
    word(&mut opaque, 0, 0x1234, 4, true);
    word(&mut opaque, 4, 8, 4, true);
    assert!(
        inspect(&thin(true, true, 2, &[opaque]))[0]
            .libraries
            .is_empty()
    );
}
#[test]
fn fat_endians_require_every_slice_and_refuse_overlap_table_ranges_and_overflow() {
    let valid = executable();
    for wide in [false, true] {
        for little in [false, true] {
            let bytes = fat(wide, little, &[valid.clone(), valid.clone()]);
            assert_eq!(inspect(&bytes).len(), 2);
            let stride = if wide { 32 } else { 20 };
            let table_end = 8 + 2 * stride;
            let width = if wide { 8 } else { 4 };
            for (offset, value) in [
                (4, 0),
                (4, 17),
                (8 + 8, 0),
                (8 + 8, (table_end - 1) as u64),
                (8 + stride + 8, table_end as u64),
                (8 + if wide { 16 } else { 12 }, 0),
            ] {
                let mut bad = bytes.clone();
                word(
                    &mut bad,
                    offset,
                    value,
                    if offset == 4 { 4 } else { width },
                    little,
                );
                refused(&bad);
            }
            let mut second = bytes.clone();
            word(
                &mut second,
                table_end + valid.len() + 20,
                u32::MAX.into(),
                4,
                true,
            );
            refused(&second);
            let mut enormous = bytes.clone();
            word(
                &mut enormous,
                8 + 8,
                if wide { u64::MAX } else { u32::MAX.into() },
                width,
                little,
            );
            refused(&enormous);
            let mut overflow = bytes.clone();
            word(
                &mut overflow,
                8 + if wide { 16 } else { 12 },
                if wide { u64::MAX } else { u32::MAX.into() },
                width,
                little,
            );
            refused(&overflow);
            refused(&bytes[..table_end - 1]);
        }
    }
    assert_eq!(inspect(&fat(true, true, &vec![valid; 16])).len(), 16);
}
#[test]
fn inspection_preserves_the_open_handle_offset_and_input_bytes() {
    let bytes = executable();
    let mut input = Input::new(&bytes);
    input.file.seek(SeekFrom::Start(19)).unwrap();
    let before = input.file.metadata().unwrap();
    assert!(tool_macho::relocatable(
        &tool_macho::inspect(&input.file).unwrap(),
        false
    ));
    assert_eq!(input.file.stream_position().unwrap(), 19);
    assert_eq!(std::fs::read(&input.path).unwrap(), bytes);
    assert_eq!(
        input.file.metadata().unwrap().modified().unwrap(),
        before.modified().unwrap()
    );
}
#[test]
fn actual_system_true_is_read_without_launching_it() {
    let mut file = File::open("/usr/bin/true").unwrap();
    file.seek(SeekFrom::Start(13)).unwrap();
    let slices = tool_macho::inspect(&file).unwrap();
    assert!(!slices.is_empty());
    assert!(slices.iter().all(|s| s.file_type == 2));
    assert!(!tool_macho::needs_usb(&slices));
    assert!(tool_macho::relocatable(&slices, false));
    assert_eq!(file.stream_position().unwrap(), 13);
    println!(
        "/usr/bin/true: {} Mach-O slice(s), needsUSB=false, relocatable=true; read only",
        slices.len()
    );
}
