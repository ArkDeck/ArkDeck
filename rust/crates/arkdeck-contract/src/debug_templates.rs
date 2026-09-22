//! Closed Debug command disclosures shared by the CLI and HDC lowering.
//! Data only: selecting a row supplies neither a target nor dispatch authority.
#[derive(Clone, Copy, Debug)]
pub struct DebugTemplateDefinition {
    pub id: &'static str,
    pub title: &'static str,
    pub command: &'static [&'static str],
    pub output_byte_budget: usize,
}

pub const DEBUG_TEMPLATES: [DebugTemplateDefinition; 4] = [
    DebugTemplateDefinition {
        id: "device.packageInventory",
        title: "Installed package inventory",
        command: &["shell", "bm", "dump", "-a"],
        output_byte_budget: 2 * 1024 * 1024,
    },
    DebugTemplateDefinition {
        id: "device.debugParameterRead",
        title: "ACE debug parameter readback",
        command: &["shell", "param", "get", "persist.ace.debug.enabled"],
        output_byte_budget: 4096,
    },
    DebugTemplateDefinition {
        id: "device.windowInventory",
        title: "Window manager inventory",
        command: &[
            "shell",
            "hidumper",
            "-s",
            "WindowManagerService",
            "-a",
            "-a",
        ],
        output_byte_budget: 8 * 1024 * 1024,
    },
    DebugTemplateDefinition {
        id: "device.uptime",
        title: "Device uptime",
        command: &["shell", "uptime"],
        output_byte_budget: 16 * 1024,
    },
];
