#!/usr/bin/env python3
# VS-07 (REQ-EVT-09) — valida um arquivo JSONL de eventos: schema por tipo,
# campos desconhecidos rejeitados, `t` monotônico não decrescente.
# Uso: python3 events_check.py <arquivo.jsonl> ; exit 0 = válido, 1 = inválido.

import json
import sys

NUM = (int, float)


def is_num(v):
    return isinstance(v, NUM) and not isinstance(v, bool)


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def is_vec3(v):
    return isinstance(v, list) and len(v) == 3 and all(is_num(x) for x in v)


def is_vec3_int(v):
    return isinstance(v, list) and len(v) == 3 and all(is_int(x) for x in v)


# tipo -> (obrigatórios, opcionais); valores são funções predicado
SCHEMAS = {
    "KeyPress": (
        {"key": is_int},
        {"key_name": lambda v: isinstance(v, str), "duration": is_num},
    ),
    "KeyRelease": (
        {"key": is_int},
        {"key_name": lambda v: isinstance(v, str)},
    ),
    "MouseMove": ({"dx": is_num, "dy": is_num}, {}),
    "MouseButton": (
        {"button": is_int, "action": lambda v: v in ("press", "release")},
        {},
    ),
    "CloseRequested": ({}, {}),
    "TeleportTo": ({"position": lambda v: is_vec3(v)}, {}),
    "LookAt": ({"target": lambda v: is_vec3(v)}, {}),
    "AddBlock": (
        {"position": is_vec3_int, "block_id": lambda v: is_int(v) and 1 <= v <= 65535},
        {},
    ),
    "RemoveBlock": ({"position": is_vec3_int}, {}),
    "Wait": ({"seconds": is_num}, {}),
    "ToggleTelemetry": ({}, {}),
    "TelemetrySnapshot": ({}, {}),
}


def validate_line(ev, line_no, errors):
    if not isinstance(ev, dict):
        errors.append(f"linha {line_no}: evento não é um objeto JSON")
        return
    t = ev.get("t")
    if not is_num(t):
        errors.append(f"linha {line_no}: 't' ausente ou não numérico")
        return
    if t < 0:
        errors.append(f"linha {line_no}: 't' negativo ({t})")
    etype = ev.get("type")
    if not isinstance(etype, str) or etype not in SCHEMAS:
        errors.append(f"linha {line_no}: tipo desconhecido {etype!r}")
        return

    required, optional = SCHEMAS[etype]
    allowed = {"t", "type"} | set(required) | set(optional)
    for k in ev:
        if k not in allowed:
            errors.append(f"linha {line_no} ({etype}): campo desconhecido '{k}'")
    for k, pred in required.items():
        if k not in ev:
            errors.append(f"linha {line_no} ({etype}): campo obrigatório '{k}' ausente")
        elif not pred(ev[k]):
            errors.append(f"linha {line_no} ({etype}): campo '{k}' com valor inválido {ev[k]!r}")
    for k, pred in optional.items():
        if k in ev and not pred(ev[k]):
            errors.append(f"linha {line_no} ({etype}): campo '{k}' com valor inválido {ev[k]!r}")
    if etype == "KeyPress" and "duration" in ev and ev["duration"] < 0:
        errors.append(f"linha {line_no} (KeyPress): duration negativo {ev['duration']!r}")
    if etype == "Wait" and ev.get("seconds", 0) < 0:
        errors.append(f"linha {line_no} (Wait): seconds negativo {ev['seconds']!r}")


def main():
    if len(sys.argv) != 2:
        print("uso: events_check.py <arquivo.jsonl>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    errors = []
    counts = {}
    last_t = None
    total = 0
    try:
        f = open(path, "r", encoding="utf-8")
    except OSError as e:
        print(f"ERRO: não foi possível abrir {path}: {e}", file=sys.stderr)
        return 1
    with f:
        for line_no, raw in enumerate(f, 1):
            line = raw.strip()
            if not line:
                continue
            total += 1
            try:
                ev = json.loads(line)
            except json.JSONDecodeError as e:
                errors.append(f"linha {line_no}: JSON inválido ({e})")
                continue
            validate_line(ev, line_no, errors)
            t = ev.get("t") if isinstance(ev, dict) else None
            if is_num(t):
                if last_t is not None and t < last_t - 1e-9:
                    errors.append(f"linha {line_no}: 't' retrocedeu ({t} < {last_t})")
                last_t = t if last_t is None else max(last_t, t)
            if isinstance(ev, dict) and isinstance(ev.get("type"), str):
                counts[ev["type"]] = counts.get(ev["type"], 0) + 1

    print(f"arquivo: {path}")
    print(f"linhas válidas de evento: {total}")
    for k in sorted(counts):
        print(f"  {k}: {counts[k]}")
    if errors:
        print(f"ERROS: {len(errors)}")
        for e in errors[:50]:
            print(f"  {e}")
        return 1
    print("OK: schema válido, 't' monotônico")
    return 0


if __name__ == "__main__":
    sys.exit(main())
