#!/bin/zsh
set -eu

if [[ $# -ne 3 ]]; then
  print -u2 "usage: build_and_sign.zsh <new-output-dir> <python-include-dir> <python-library-dir>"
  exit 64
fi

output_root="$1"
python_include="$2"
python_library="$3"
script_root="${0:A:h}"
partition_root="${script_root:h}"
repo_root="${partition_root:h:h}"
app_root="${output_root}/ArkDeckPartitionDecodeBroker.app"
contents_root="${app_root}/Contents"
macos_root="${contents_root}/MacOS"
resources_root="${contents_root}/Resources"

if [[ -e "${output_root}" ]]; then
  print -u2 "refusing existing output directory"
  exit 65
fi
if [[ ! -f "${python_include}/Python.h" ]]; then
  print -u2 "Python.h missing"
  exit 66
fi
if [[ ! -d "${python_library}" ]]; then
  print -u2 "Python library directory missing"
  exit 67
fi

/bin/mkdir -p "${macos_root}" "${resources_root}"
/usr/bin/install -m 0644 "${script_root}/Info.plist" "${contents_root}/Info.plist"
/usr/bin/install -m 0644 "${script_root}/Broker.entitlements" "${resources_root}/Broker.entitlements"
/usr/bin/install -m 0644 "${script_root}/main.m" "${resources_root}/main.m"
/usr/bin/install -m 0644 "${script_root}/policy.json" "${resources_root}/policy.json"
/usr/bin/install -m 0644 "${partition_root}/decode.py" "${resources_root}/decode.py"
/usr/bin/install -m 0644 "${partition_root}/evidence.py" "${resources_root}/evidence.py"
/usr/bin/install -m 0644 "${partition_root}/broker_entry.py" "${resources_root}/broker_entry.py"
/usr/bin/install -m 0644 \
  "${repo_root}/openspec/changes/archive/2026-07-18-chg-2026-003-dayu200-image-characterization/evidence/member-inventory.json" \
  "${resources_root}/member-inventory.json"

/usr/bin/xcrun clang \
  -fobjc-arc \
  -Wall \
  -Wextra \
  -Werror \
  -Wno-deprecated-declarations \
  -mmacosx-version-min=26.0 \
  -I "${python_include}" \
  -L "${python_library}" \
  -Wl,-rpath,/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/lib \
  "${script_root}/main.m" \
  -lpython3.14 \
  -ldl \
  -lsandbox \
  -framework AppKit \
  -framework CoreFoundation \
  -framework Foundation \
  -framework Security \
  -o "${macos_root}/ArkDeckPartitionDecodeBroker"

/usr/bin/codesign \
  --force \
  --sign - \
  --identifier io.arkdeck.partition-decode-broker \
  --entitlements "${script_root}/Broker.entitlements" \
  "${app_root}"
/usr/bin/codesign --verify --strict --verbose=4 "${app_root}"

print "BROKER_APP=${app_root}"
