# Keyboard Provider contract

The following primary sources were read at fixed commits on 2026-10-04:

- [UiTest input parser](https://github.com/openharmony/testfwk_arkxtest/blob/a9a8b4700b0b79ee0057f36de6e351d7e647a656/uitest/input/ui_input.cpp): `keyEvent` and focused `text`; the latter is an API-18-era interface. Both print the API error description, including on an error with process status zero.
- [UiTest driver](https://github.com/openharmony/testfwk_arkxtest/blob/a9a8b4700b0b79ee0057f36de6e351d7e647a656/uitest/core/ui_driver.cpp): text first maps to key events, falling back to clipboard + paste when unsupported, explicitly requested or longer than its threshold.
- [UiTest error definitions](https://github.com/openharmony/testfwk_arkxtest/blob/a9a8b4700b0b79ee0057f36de6e351d7e647a656/uitest/core/frontend_error_defines.h): positive acknowledgement is `No Error`.
- [HDC host argument join](https://github.com/openharmony/developtools_hdc/blob/8920c56c9b691730c7dbd4cafa9245d615e2c583/src/host/main.cpp): arguments containing spaces acquire another quote layer.
- [OpenHarmony key constants](https://github.com/openharmony/multimodalinput_input/blob/db4e5e4ccc9f3075a8673a4eb75050d1b2b80175/frameworks/proxy/events/src/key_event.cpp): the ten reviewed symbolic keys map to fixed numeric codes.

The executable is the Runtime-retained HDC; argv begins `-t <exact bound key>`.
Keys lower to fixed `shell uitest uiInput keyEvent <reviewed code>` tokens.
Text lowers to fixed `shell uitest uiInput text` plus one ASCII-only argument:
a double-quoted command substitution invoking the shell printf builtin with
`%b` and octal encodings of every payload byte. `${IFS}` separates the fixed
printf operands so no argv token contains a literal space that HDC can re-quote.
No payload character participates in shell syntax. NUL/control characters are
refused; printable whitespace inside the text remains one argument. Local shell
fixtures test HDC's join against Unicode, quotes, metacharacters and whitespace.
This is a closed Provider lowering; callers can provide neither argv nor shell.

Each process is bounded to 30 seconds and 4096 captured bytes. Only exit zero,
empty stderr, no truncation and exactly `No Error` followed by LF or CRLF is
accepted. Every other post-launch receipt is unknown. Tool streams are inspected
only in memory and discarded. No operation output Artifact is declared.
The retained private source is the only text-bearing Artifact. Persistence has
exactly `sourceArtifactId` and `sourceSha256`; recovery validates those fields
without reading the private source or dispatching any command.

Acknowledgement cannot prove current focus, inserted text, application behavior
or a device clipboard value. The App exposes the clipboard side effect and asks
users to inspect the device. It never labels injector acceptance as application
verification. It clears its local draft before dispatch and on target change or
leaving the workspace. No input automatically repeats, restores the clipboard,
or sends a compensating key after uncertain execution.
