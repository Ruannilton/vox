#!/usr/bin/env python3
"""Simulacao da maquina de estados B1 (VS-01, REQ-SIM-02).

Modela ChunkManager + worker + timelines (compute e grafica) e verifica as
invariantes da ADR-B1 sob interleavings aleatorios (seed fixa) e cenarios
dirigidos:

  I1  toda tarefa esta em exatamente um conjunto {pendentes, submetidos}
  I2  slot livre nunca referenciado por tarefa pendente/submetida
  I3  slot nao esta livre enquanto ativo ou aposentado
  I4  valores de timeline dos lotes sao estritamente crescentes (1 claim = 1 lote = 1 valor)
  I5  conclusao so promove com (coord, slot, geracao) casando (anti-ABA)
  I6  slot de lote em voo so volta ao pool apos a timeline de compute passar
"""

import random
import sys

MAX_BATCH = 16
GENERATING, CACHED, RENDERABLE = "GENERATING", "CACHED", "RENDERABLE"

FAILURES = []


def fail(msg):
    FAILURES.append(msg)
    print(f"  FAIL: {msg}")


class Sim:
    def __init__(self, slot_count=8):
        self.slot_count = slot_count
        self.free_slots = list(range(slot_count))
        self.slot_generations = [0] * slot_count
        self.active = {}          # coord -> [state, slot, generation]
        self.pending = []         # tasks: (coord, slot, gen)
        self.submitted = []       # batches: [value, [tasks]]
        self.retiring_compute = []   # (slot, release_value)
        self.retiring_graphics = []  # (slot, release_frame)
        self.compute_completed = 0
        self.frame = 0
        self.next_batch_value = 1
        self.coord_seq = 0

    # --- invariantes globais ---
    def check_invariants(self):
        all_tasks = list(self.pending) + [t for _, tasks in self.submitted for t in tasks]
        # I1: identidade completa (coord, slot, gen) em exatamente um conjunto
        ids = {}
        for t in self.pending:
            ids[t] = ids.get(t, 0) + 1
        for _, tasks in self.submitted:
            for t in tasks:
                ids[t] = ids.get(t, 0) + 1
        for t, n in ids.items():
            if n != 1:
                fail(f"I1 violada: tarefa {t} aparece {n} vezes")
        # I2/I3: slot livre nao pode ser referenciado
        busy = {t[1] for t in all_tasks}
        busy |= {slot for _, (state, slot, gen) in ((c, r) for c, r in self.active.items()) for _ in [0]}
        busy = {t[1] for t in all_tasks} | {r[1] for r in self.active.values()}
        busy |= {s for s, _ in self.retiring_compute} | {s for s, _ in self.retiring_graphics}
        for s in self.free_slots:
            if s in busy:
                fail(f"I2/I3 violada: slot {s} livre mas referenciado")
        # I4: valores crescentes
        values = [v for v, _ in self.submitted]
        if values != sorted(values) or len(set(values)) != len(values):
            fail(f"I4 violada: valores {values}")
        # I4b: nenhum lote pendente com valor <= ja completado
        for v, _ in self.submitted:
            if v <= self.compute_completed:
                fail(f"I4 violada: lote {v} submetido mas timeline ja em {self.compute_completed}")

    # --- operacoes da thread principal ---
    def request(self, coord):
        if coord in self.active or not self.free_slots:
            return False
        slot = self.free_slots.pop()
        self.slot_generations[slot] += 1
        gen = self.slot_generations[slot]
        self.active[coord] = [GENERATING, slot, gen]
        self.pending.append((coord, slot, gen))
        return True

    def unload(self, coord):
        if coord not in self.active:
            return
        state, slot, gen = self.active[coord]
        if state == GENERATING:
            self.retire_generating_slot(coord, slot, gen)
        else:
            self.retiring_graphics.append((slot, self.frame))
        del self.active[coord]

    def retire_generating_slot(self, coord, slot, gen):
        # (a) ainda pendente: cancela e libera na hora
        for i, t in enumerate(self.pending):
            if t == (coord, slot, gen):
                self.pending.pop(i)
                self.free_slots.append(slot)
                return
        # (b) submetida: aposentadoria pela timeline de compute do lote
        for value, tasks in self.submitted:
            if (coord, slot, gen) in tasks:
                self.retiring_compute.append((slot, value))
                return
        # (c) defensivo: nenhuma escrita pendente
        self.free_slots.append(slot)

    def completion_handler(self):
        remaining = []
        for value, tasks in self.submitted:
            if value > self.compute_completed:
                remaining.append([value, tasks])
                continue
            for coord, slot, gen in tasks:
                if coord in self.active:
                    rec = self.active[coord]
                    # I5: anti-ABA
                    if rec[0] == GENERATING and rec[1] == slot and rec[2] == gen:
                        rec[0] = CACHED
        self.submitted = remaining
        # I6: libera aposentados de compute cuja timeline passou
        keep = []
        for slot, value in self.retiring_compute:
            if value <= self.compute_completed:
                self.free_slots.append(slot)
            else:
                keep.append((slot, value))
        self.retiring_compute = keep

    def graphics_frame(self):
        self.frame += 1
        keep = []
        for slot, value in self.retiring_graphics:
            if value <= self.frame:
                self.free_slots.append(slot)
            else:
                keep.append((slot, value))
        self.retiring_graphics = keep

    # --- worker (claim atomico) ---
    def worker_claim(self):
        if not self.pending:
            return False
        tasks = self.pending[:MAX_BATCH]
        self.pending = self.pending[MAX_BATCH:]
        # claim atomico: publica ANTES de qualquer "trabalho GPU"
        self.submitted.append([self.next_batch_value, tasks])
        self.next_batch_value += 1
        return True

    def gpu_complete_oldest(self):
        if not self.submitted:
            return False
        self.compute_completed = self.submitted[0][0]
        return True


def scenario(name, fn):
    print(f"[cenario] {name}")
    before = len(FAILURES)
    fn()
    if len(FAILURES) == before:
        print("  ok")


def scen_cancel_before_claim():
    s = Sim()
    s.request((0, 0, 0))
    slot = s.active[(0, 0, 0)][1]
    s.check_invariants()
    s.unload((0, 0, 0))          # caminho (a)
    s.check_invariants()
    assert slot in s.free_slots, "slot nao liberado no cancelamento (a)"
    s.request((0, 0, 0))         # realoca: geracao nova
    assert s.active[(0, 0, 0)][2] == 2, "geracao nao incrementou"


def scen_cancel_after_submit():
    s = Sim()
    s.request((0, 0, 0))
    slot = s.active[(0, 0, 0)][1]
    s.worker_claim()
    s.check_invariants()
    s.unload((0, 0, 0))          # caminho (b): aposentadoria compute
    s.check_invariants()
    assert slot not in s.free_slots, "slot liberado com lote em voo (I6)"
    s.gpu_complete_oldest()
    s.completion_handler()
    s.check_invariants()
    assert slot in s.free_slots, "slot nao liberado apos timeline"


def scen_stale_completion_aba():
    # Conclusao VENCIDA (geracao antiga, mesmo coord+slot) nao promove o chunk novo.
    s = Sim()
    # chunk vivo na geracao 2 (recriado apos descarregar a geracao 1)
    s.slot_generations[5] = 2
    s.free_slots.remove(5)
    s.active[(0, 0, 0)] = [GENERATING, 5, 2]
    s.pending.append(((0, 0, 0), 5, 2))
    # lote antigo ainda em voo, referenciando a geracao 1 do mesmo slot
    s.submitted.append([1, [((0, 0, 0), 5, 1)]])
    s.next_batch_value = 2
    s.compute_completed = 1
    s.completion_handler()
    s.check_invariants()
    assert s.active[(0, 0, 0)][0] == GENERATING, "ABA: conclusao vencida promoveu chunk novo"
    # e a conclusao da geracao correta promove normalmente
    s.worker_claim()
    s.gpu_complete_oldest()
    s.completion_handler()
    s.check_invariants()
    assert s.active[(0, 0, 0)][0] == CACHED, "conclusao valida nao promoveu"


def scen_batch16_partial_cancel():
    s = Sim(slot_count=16)
    for i in range(16):
        s.request((i, 0, 0))
    s.worker_claim()
    assert len(s.submitted[0][1]) == 16, "lote nao drenou 16"
    for i in (3, 7, 15):
        s.unload((i, 0, 0))
    s.check_invariants()
    s.gpu_complete_oldest()
    s.completion_handler()
    s.check_invariants()
    cached = sum(1 for r in s.active.values() if r[0] == CACHED)
    assert cached == 13, f"esperava 13 CACHED, obteve {cached}"
    assert len(s.free_slots) == 3


def scen_random_interleavings():
    rng = random.Random(20261104)
    s = Sim(slot_count=8)
    coords = [(i % 4, 0, i // 4) for i in range(12)]
    for step in range(20000):
        op = rng.randrange(6)
        if op == 0:
            s.request(rng.choice(coords))
        elif op == 1:
            s.unload(rng.choice(coords))
        elif op == 2:
            s.worker_claim()
        elif op == 3:
            s.gpu_complete_oldest()
            s.completion_handler()
        elif op == 4:
            s.graphics_frame()
        else:
            s.completion_handler()
        if step % 97 == 0:
            s.check_invariants()
    s.check_invariants()


def main():
    scenario("cancelamento antes do claim (a)", scen_cancel_before_claim)
    scenario("cancelamento apos submit (b)", scen_cancel_after_submit)
    scenario("conclusao vencida (ABA)", scen_stale_completion_aba)
    scenario("lote de 16 com cancelamento parcial", scen_batch16_partial_cancel)
    scenario("interleavings aleatorios (seed 20261104, 20k passos)", scen_random_interleavings)

    print(f"\n{'FALHOU' if FAILURES else 'PASSOU'}: {len(FAILURES)} falhas")
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
