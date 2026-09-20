#!/usr/bin/env python3
"""The Swift runtime's `DecodingError` rendering, which no harness compares.

A Swift owner interpolates Swift's `DecodingError` into some refusal messages
(`undecodable current request: \\(error)`, `indexCorrupted("undecodable artifact
index: …")`). That rendering belongs to the Swift runtime, not to ArkDeck, and
it changes with the host's OS: on 2026-09-15 this machine moved to macOS 27.0,
after the analyzer and quota oracles were recorded, and its runtime now writes

  `typeMismatch: Expected value of type X.`   where the oracles say `expected`,
  `valueNotFound: Expected value of type X.`  where they add `but found null
                                               instead`.

Under CHG-2026-074 r11 section 3 a `message` text and a Swift debug rendering
are T2 and not compared, so the drift is not a parity defect; it is the two
older harnesses, which compare every message byte for byte, that are stricter
than the policy. They now read the rendering as a label instead.

What stays compared: the error code, the answer's shape and order, the zero
dispatch proof, the ArkDeck wording around the rendering (`undecodable current
request: `, the `indexCorrupted("…")` spelling of the Swift error case) and the
`DecodingError` case the runtime names. Only the runtime's own sentence after
that case goes. The check scripts load this module by file name, as they load
one another.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

LABEL = '<Swift runtime rendering>'
CASE = re.compile(r'DecodingError\.([A-Za-z][A-Za-z0-9]*): ')
WRAPPED = re.compile(r'^([A-Za-z][A-Za-z0-9]*)\("(.*)"\)$', re.S)


def masked_text(text: str) -> str:
    """`text` with the runtime's rendering read as a label, or `text` itself."""
    wrapper = WRAPPED.match(text)
    if wrapper:
        inner = masked_text(wrapper.group(2))
        return f'{wrapper.group(1)}("{inner}")' if inner != wrapper.group(2) else text
    case = CASE.search(text)
    return text[:case.end()] + LABEL if case else text


def masked(value):
    """`value` with every such rendering in it read as a label."""
    if isinstance(value, dict):
        return {key: masked(item) for key, item in value.items()}
    if isinstance(value, list):
        return [masked(item) for item in value]
    return masked_text(value) if isinstance(value, str) else value


def _strings(value):
    """Every string in `value`, in order."""
    if isinstance(value, dict):
        for item in value.values():
            yield from _strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from _strings(item)
    elif isinstance(value, str):
        yield value


def _self_test() -> None:
    """Every recorded rendering is read as a label; nothing else is."""
    root = Path(__file__).resolve().parents[2] / 'rust/tests/fixtures'
    recorded: list[str] = []

    def walk(value) -> None:
        if isinstance(value, dict):
            for item in value.values():
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)
        elif isinstance(value, str) and 'DecodingError.' in value:
            recorded.append(value)

    for oracle in ('job-plan-analyzer', 'artifact-quota'):
        walk(json.loads((root / oracle / 'cases.json').read_text()))
    assert len(recorded) >= 24, len(recorded)
    cases = set()
    for message in recorded:
        label = masked_text(message)
        case = CASE.search(message)
        cases.add(case.group(1))
        assert label.endswith(LABEL + ('")' if message.endswith('")') else '')), label
        assert label.startswith(message[:case.end()]), label
        assert 'Debug description' not in label, label
    assert cases == {'typeMismatch', 'valueNotFound', 'keyNotFound', 'dataCorrupted'}, cases

    # The two macOS 27 spellings read as their recorded counterparts.
    for recorded_text, live in [
        ('undecodable current request: DecodingError.typeMismatch: expected value of type'
         ' Dictionary<String, Any>. Debug description: Expected to decode Dictionary<String, Any>'
         ' but found an array instead.',
         'undecodable current request: DecodingError.typeMismatch: Expected value of type'
         ' Dictionary<String, Any>. Debug description: Expected to decode Dictionary<String, Any>'
         ' but found an array instead.'),
        ('undecodable current request: DecodingError.valueNotFound: Expected value of type'
         ' Dictionary<String, Any> but found null instead. Debug description: Cannot get keyed'
         ' decoding container -- found null value instead',
         'undecodable current request: DecodingError.valueNotFound: Expected value of type'
         ' Dictionary<String, Any>. Debug description: Cannot get keyed decoding container --'
         ' found null value instead'),
        ('indexCorrupted("undecodable artifact index: DecodingError.typeMismatch: expected value'
         ' of type Int. Path: artifacts[0].byteCount. Debug description: Expected to decode Int'
         ' but found a string instead.")',
         'indexCorrupted("undecodable artifact index: DecodingError.typeMismatch: Expected value'
         ' of type Int. Path: artifacts[0].byteCount. Debug description: Expected to decode Int'
         ' but found a string instead.")'),
    ]:
        assert masked_text(recorded_text) == masked_text(live), live
        assert recorded_text != live

    # Nothing else is hidden: another code, another DecodingError case, other
    # ArkDeck wording, a wrapper of another Swift error case, or a message
    # without a rendering still differs.
    recorded_text = recorded[0]
    other_case = recorded_text.replace('DecodingError.typeMismatch:', 'DecodingError.keyNotFound:')
    other_prefix = recorded_text.replace('undecodable current request: ', 'undecodable next request: ')
    for other in (other_case, other_prefix):
        assert masked_text(other) != masked_text(recorded_text), other
    quota = 'indexCorrupted("undecodable artifact index: DecodingError.typeMismatch: x")'
    assert masked_text(quota) != masked_text(quota.replace('indexCorrupted', 'ioFailure'))
    plain = 'artifactNotFound("ART-cf645cc2f23c16cf9965b179bcb35b5e")'
    assert masked_text(plain) == plain
    assert masked({'ok': False, 'error': {'code': 'invalidInput', 'message': recorded_text}}) == {
        'ok': False, 'error': {'code': 'invalidInput', 'message': masked_text(recorded_text)}}
    assert masked({'ok': False, 'error': {'code': 'internalError', 'message': recorded_text}}) != {
        'ok': False, 'error': {'code': 'invalidInput', 'message': masked_text(recorded_text)}}
    # Over both oracles, every string but those renderings is left alone.
    changed = 0
    for oracle in ('job-plan-analyzer', 'artifact-quota'):
        document = json.loads((root / oracle / 'cases.json').read_text())
        for before, after in zip(_strings(document), _strings(masked(document)), strict=True):
            if before != after:
                assert 'DecodingError.' in before, before
                changed += 1
    assert changed == len(recorded), (changed, len(recorded))

    print(json.dumps({'result': 'PASS', 'recordedRenderings': len(recorded),
                      'maskedStrings': changed, 'cases': sorted(cases)}, sort_keys=True))


if __name__ == '__main__':
    if sys.argv[1:] != ['--self-test']:
        raise SystemExit('usage: decoding-error-wording.py --self-test')
    _self_test()
