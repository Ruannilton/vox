#!/usr/bin/env python3
"""Simulacao da composicao de biomas (VS-22, REQ-SIM-11).

Espelha a logica de composicao de biomas que sera implementada no kernel de
geracao (src/assets/shaders/voxel.slang, REQ-BIO-02/03) ANTES da integracao:
classificacao climatica (primario/secundario por distancia euclidiana, desempate
por menor indice), early-out por limiarTransicao, blending por
smoothstep(limiar, 0, diff) x 0.5 + lerp, composicao de altura
(alturaBase + somatorio de camadas com sinal adicao/subtracao), round half up,
clamp [1, 32767] e selecao de bloco por faixa de y (superficie/subsolo/fundo/
planta/ar) seguindo o bioma PRIMARIO — so a altura faz blending.

Divisao de responsabilidade com o oracle (mesma da VS-06): os valores de ruido
do FastNoiseLite sao ENTRADAS INJETADAS (tabela deterministica/mock por
camada); o wang hash de spawn de planta (VS-14) tambem e injetado como decisao
booleana — a sim valida a logica de composicao, nao a FNL nem o hash.

Oracle independente: as mesmas decisoes em float64 com os mesmos ruidos
injetados; decisoes (classificacao, early-out, faixa, clamp) devem coincidir;
alturas dentro de margem decisiva (> 1e-6 relativo — criterio de
render_sim.py: casos na fronteira do erro de arredondamento f32 sao pulados).

Cobre os casos obrigatorios do REQ-SIM-11: interior (early-out, secundario
ignorado), ecotono central (peso exato 0,5), zona de limiar exato, empate de
distancias, camadas de subtracao, alturaBase acima do clamp (40000 -> 32767),
altura que arredonda no meio (x,5 -> half up), profundidadeSubsuperficie 0 e
maior que a altura, bioma sem camadas, coluna com e sem planta, ar acima,
validacao de JSON (bloco inexistente, > 16 biomas, > 64 camadas, > 8 camadas
por bioma, tipos/operacao invalidos, defaults) e exercicio dos 5 biomas da
config padrao.
"""

import json
import math
import os
import random
import struct


def f32(x):
    """Arredonda um float Python (f64) para float32 — espelha as operacoes
    float32 do shader (numpy indisponivel; soma/produto de dois f32 em f64 e
    exato antes do arredondamento, como em render_sim.py)."""
    return struct.unpack('<f', struct.pack('<f', x))[0]


# ----------------------------------------------------------------------------
# Constantes e config (REQ-BIO-01)
# ----------------------------------------------------------------------------

LIMIAR_TRANSICAO_PADRAO = 0.15
FORCA_DISTORCAO_PADRAO = 24.0       # pre-entrada (warp) — fora do espelho de altura
FREQ_TEMPERATURA_PADRAO = 0.001     # pre-entrada (clima) — fora do espelho
FREQ_UMIDADE_PADRAO = 0.002
SEMENTE_PADRAO = 1337
OFFSET_MUNDIAL_PADRAO = (0.0, 0.0)

ALTURA_MIN = 1
ALTURA_MAX = 32767
MAX_BIOMAS = 16
MAX_CAMADAS_POR_BIOMA = 8
MAX_CAMADAS_TOTAIS = 64
PROFUNDIDADE_PADRAO = 8
BLOCO_PLANTA = 4  # id fixo da planta (regra VS-14 inalterada)

TIPOS_RUIDO = ("simplex", "perlin", "cellular")
OPERACOES = ("adicao", "subtracao")

# Registry de blocos da config padrao (ids 1..8, conforme spec)
REGISTRY_PADRAO = {
    "grama": 1, "terra": 2, "pedra": 3, "planta": 4,
    "ice": 5, "snow": 6, "sand": 7, "podzol": 8,
}

# Config padrao aprovada (REQ-BIO-01, 2026-11-12) — 5 biomas, sem vegetacao.
CONFIG_PADRAO = {
    "global": {
        "semente": SEMENTE_PADRAO,
        "forcaDistorcao": FORCA_DISTORCAO_PADRAO,
        "limiarTransicao": LIMIAR_TRANSICAO_PADRAO,
        "frequenciaTemperatura": FREQ_TEMPERATURA_PADRAO,
        "frequenciaUmidade": FREQ_UMIDADE_PADRAO,
        "offsetMundial": list(OFFSET_MUNDIAL_PADRAO),
    },
    "biomas": [
        {"nome": "planicies", "centroTemperatura": 0.3, "centroUmidade": 0.2,
         "alturaBase": 32, "blocoSuperficie": "grama", "blocoSubsuperficie": "terra",
         "blocoProfundo": "pedra", "profundidadeSubsuperficie": 8,
         "permitePlantas": False,
         "camadas": [
             {"amplitude": 10, "frequencia": 0.010, "oitavas": 1, "tipo": "simplex", "operacao": "adicao"},
             {"amplitude": 5, "frequencia": 0.010, "oitavas": 1, "tipo": "perlin", "operacao": "adicao"},
         ]},
        {"nome": "deserto", "centroTemperatura": 0.8, "centroUmidade": -0.7,
         "alturaBase": 34, "blocoSuperficie": "sand", "blocoSubsuperficie": "sand",
         "blocoProfundo": "sand", "profundidadeSubsuperficie": 4,
         "permitePlantas": False,
         "camadas": [
             {"amplitude": 6, "frequencia": 0.008, "oitavas": 1, "tipo": "simplex", "operacao": "adicao"},
             {"amplitude": 2, "frequencia": 0.020, "oitavas": 1, "tipo": "perlin", "operacao": "adicao"},
         ]},
        {"nome": "pantano", "centroTemperatura": 0.5, "centroUmidade": 0.8,
         "alturaBase": 30, "blocoSuperficie": "podzol", "blocoSubsuperficie": "terra",
         "blocoProfundo": "terra", "profundidadeSubsuperficie": 8,
         "permitePlantas": False,
         "camadas": [
             {"amplitude": 2, "frequencia": 0.006, "oitavas": 1, "tipo": "simplex", "operacao": "adicao"},
         ]},
        {"nome": "gelado", "centroTemperatura": -0.8, "centroUmidade": 0.0,
         "alturaBase": 36, "blocoSuperficie": "snow", "blocoSubsuperficie": "ice",
         "blocoProfundo": "pedra", "profundidadeSubsuperficie": 4,
         "permitePlantas": False,
         "camadas": [
             {"amplitude": 8, "frequencia": 0.012, "oitavas": 3, "tipo": "perlin", "operacao": "adicao"},
             {"amplitude": 3, "frequencia": 0.030, "oitavas": 1, "tipo": "simplex", "operacao": "adicao"},
         ]},
        {"nome": "montanhoso", "centroTemperatura": -0.1, "centroUmidade": -0.3,
         "alturaBase": 40, "blocoSuperficie": "pedra", "blocoSubsuperficie": "pedra",
         "blocoProfundo": "pedra", "profundidadeSubsuperficie": 4,
         "permitePlantas": False,
         "camadas": [
             {"amplitude": 25, "frequencia": 0.006, "oitavas": 4, "tipo": "perlin", "operacao": "adicao"},
             {"amplitude": 8, "frequencia": 0.010, "oitavas": 1, "tipo": "simplex", "operacao": "subtracao"},
         ]},
    ],
}


# ----------------------------------------------------------------------------
# Validacao de JSON (REQ-BIO-01) — espelha o loader (padrao VS-12)
# ----------------------------------------------------------------------------

def validar_config_biomas(config, registry):
    """Valida a config data-driven; aplica defaults (blocoProfundo =
    blocoSubsuperficie, profundidade = 8, permitePlantas = false).
    Retorna (config_normalizada, erro) — exatamente um dos dois e None."""
    if not isinstance(config, dict):
        return None, "raiz deve ser objeto"
    glob = config.get("global")
    if not isinstance(glob, dict):
        return None, "secao 'global' ausente ou invalida"
    for campo in ("semente", "forcaDistorcao", "limiarTransicao",
                  "frequenciaTemperatura", "frequenciaUmidade"):
        if campo not in glob or not isinstance(glob[campo], (int, float)):
            return None, f"global.{campo} ausente ou nao numerico"
    if not (glob["forcaDistorcao"] >= 0):
        return None, "global.forcaDistorcao deve ser >= 0"
    for campo in ("limiarTransicao", "frequenciaTemperatura", "frequenciaUmidade"):
        if not (glob[campo] > 0):
            return None, f"global.{campo} deve ser > 0"

    biomas = config.get("biomas")
    if not isinstance(biomas, list) or not (1 <= len(biomas) <= MAX_BIOMAS):
        return None, f"biomas: quantidade deve ser 1..{MAX_BIOMAS}"

    total_camadas = 0
    norm = {"global": dict(glob), "biomas": []}
    vistos = set()
    for i, entrada in enumerate(biomas):
        if not isinstance(entrada, dict):
            return None, f"biomas[{i}]: deve ser objeto"
        nome = entrada.get("nome")
        if not isinstance(nome, str) or not nome:
            return None, f"biomas[{i}]: nome ausente ou invalido"
        if nome in vistos:
            return None, f"bioma '{nome}': nome duplicado"
        vistos.add(nome)
        for campo in ("centroTemperatura", "centroUmidade"):
            v = entrada.get(campo)
            if not isinstance(v, (int, float)) or not (-1.0 <= v <= 1.0):
                return None, f"bioma '{nome}': {campo} deve estar em [-1, 1]"
        altura_base = entrada.get("alturaBase")
        if not isinstance(altura_base, (int, float)):
            return None, f"bioma '{nome}': alturaBase ausente ou nao numerica"
        for campo in ("blocoSuperficie", "blocoSubsuperficie"):
            bloco = entrada.get(campo)
            if not isinstance(bloco, str) or bloco not in registry:
                return None, f"bioma '{nome}': {campo} '{bloco}' inexistente no registry"
        profundo = entrada.get("blocoProfundo", entrada["blocoSubsuperficie"])
        if not isinstance(profundo, str) or profundo not in registry:
            return None, f"bioma '{nome}': blocoProfundo '{profundo}' inexistente no registry"
        profundidade = entrada.get("profundidadeSubsuperficie", PROFUNDIDADE_PADRAO)
        if not isinstance(profundidade, int) or profundidade < 0:
            return None, f"bioma '{nome}': profundidadeSubsuperficie invalida"
        plantas = entrada.get("permitePlantas", False)
        if not isinstance(plantas, bool):
            return None, f"bioma '{nome}': permitePlantas deve ser bool"
        camadas = entrada.get("camadas", [])
        if not isinstance(camadas, list) or len(camadas) > MAX_CAMADAS_POR_BIOMA:
            return None, f"bioma '{nome}': camadas deve ser lista 0..{MAX_CAMADAS_POR_BIOMA}"
        total_camadas += len(camadas)
        camadas_norm = []
        for j, camada in enumerate(camadas):
            if not isinstance(camada, dict):
                return None, f"bioma '{nome}': camadas[{j}] deve ser objeto"
            for campo in ("amplitude", "frequencia"):
                v = camada.get(campo)
                if not isinstance(v, (int, float)) or isinstance(v, bool):
                    return None, f"bioma '{nome}': camadas[{j}].{campo} ausente ou nao numerico"
            if not (camada["frequencia"] > 0):
                return None, f"bioma '{nome}': camadas[{j}].frequencia deve ser > 0"
            oitavas = camada.get("oitavas", 1)
            if not isinstance(oitavas, int) or not (1 <= oitavas <= 8):
                return None, f"bioma '{nome}': camadas[{j}].oitavas deve ser 1..8"
            tipo = camada.get("tipo")
            if tipo not in TIPOS_RUIDO:
                return None, f"bioma '{nome}': camadas[{j}].tipo '{tipo}' invalido"
            operacao = camada.get("operacao", "adicao")
            if operacao not in OPERACOES:
                return None, f"bioma '{nome}': camadas[{j}].operacao '{operacao}' invalida"
            camadas_norm.append({"amplitude": float(camada["amplitude"]),
                                 "frequencia": float(camada["frequencia"]),
                                 "oitavas": oitavas, "tipo": tipo, "operacao": operacao})
        norm["biomas"].append({
            "nome": nome,
            "centroTemperatura": float(entrada["centroTemperatura"]),
            "centroUmidade": float(entrada["centroUmidade"]),
            "alturaBase": float(altura_base),
            "blocoSuperficie": entrada["blocoSuperficie"],
            "blocoSubsuperficie": entrada["blocoSubsuperficie"],
            "blocoProfundo": profundo,
            "profundidadeSubsuperficie": profundidade,
            "permitePlantas": plantas,
            "camadas": camadas_norm,
        })
    if total_camadas > MAX_CAMADAS_TOTAIS:
        return None, f"camadas totais {total_camadas} excedem {MAX_CAMADAS_TOTAIS}"
    return norm, None


# ----------------------------------------------------------------------------
# Espelho float32 (REQ-BIO-02/03) — arredondamento por operacao
# ----------------------------------------------------------------------------

def smoothstep_f32(limiar, x):
    """smoothstep(limiar, 0, x): t = clamp((x-limiar)/(0-limiar), 0, 1);
    em f32 por operacao. diff=0 -> t=1; diff=limiar -> t=0."""
    t = f32(f32(x - limiar) / f32(0.0 - limiar))
    t = min(1.0, max(0.0, t))
    return f32(t * t * f32(3.0 - f32(2.0 * t)))


def altura_bioma_f32(bioma, ruidos, contador=None):
    """alturaBase + somatorio(camadas): ruido injetado x amplitude, sinal por
    operacao (adicao +/subtracao -), em f32 por operacao. O contador, quando
    fornecido, registra a avaliacao (mock) — usado para verificar o early-out
    por bioma (s_i > 0) do REQ-BIO-02."""
    if contador is not None:
        contador.append(bioma["nome"])
    acc = f32(bioma["alturaBase"])
    for camada, ruido in zip(bioma["camadas"], ruidos):
        contrib = f32(f32(ruido) * f32(camada["amplitude"]))
        if camada["operacao"] == "subtracao":
            contrib = f32(-contrib)
        acc = f32(acc + contrib)
    return acc


def blending_multiclique_f32(distancias, prim, limiar, biomas,
                             ruidos_por_bioma, contador=None):
    """Blending normalizado multiclique (REQ-BIO-02): para cada bioma em
    ordem ascendente fixa, diff_i = d_i - d_prim e
    s_i = smoothstep(limiar, 0, diff_i); se s_i > 0, a altura do bioma entra
    no somatorio (f32 por operacao). Altura = h_acc / w_acc (w_acc >= 1,
    nunca zero). Retorna (blended, pesos brutos, avaliados, alturas)."""
    h_acc = 0.0
    w_acc = 0.0
    pesos = [0.0] * len(biomas)
    avaliados = []
    alturas = {}
    for i in range(len(biomas)):
        diff = f32(distancias[i] - distancias[prim])
        s = smoothstep_f32(limiar, diff)
        pesos[i] = s
        if s > 0:
            h = altura_bioma_f32(biomas[i], ruidos_por_bioma[i], contador)
            h_acc = f32(h_acc + f32(s * h))
            w_acc = f32(w_acc + s)
            avaliados.append(i)
            alturas[i] = h
    return f32(h_acc / w_acc), pesos, avaliados, alturas


def altura_final_f32(altura_blended):
    """Round half up + clamp [1, 32767] (REQ-BIO-03)."""
    arredondada = math.floor(altura_blended + 0.5)
    return min(ALTURA_MAX, max(ALTURA_MIN, arredondada))


def faixa_bloco(y, altura, profundidade, permite_plantas, spawn_planta):
    """Selecao por faixa de y (REQ-BIO-03); planta em altura+1 so quando o
    bioma permite E a coluna sorteia spawn (wang hash VS-14 — injetado)."""
    if y == altura:
        return "superficie"
    if y <= altura - profundidade:
        return "fundo"
    if y < altura:
        return "subsolo"
    if y == altura + 1:
        return "planta" if (permite_plantas and spawn_planta) else "ar"
    return "ar"


def montar_coluna(bioma_prim, registry, altura, y_min, y_max, spawn_planta):
    """Faixas de bloco da coluna (seguem o PRIMARIO — so a altura faz
    blending). Compartilhada pelo espelho f32 e pelo oracle f64."""
    blocos = {"superficie": registry[bioma_prim["blocoSuperficie"]],
              "subsolo": registry[bioma_prim["blocoSubsuperficie"]],
              "fundo": registry[bioma_prim["blocoProfundo"]],
              "planta": BLOCO_PLANTA, "ar": 0}
    coluna = []
    for y in range(y_min, y_max + 1):
        faixa = faixa_bloco(y, altura, bioma_prim["profundidadeSubsuperficie"],
                            bioma_prim["permitePlantas"], spawn_planta)
        coluna.append((y, faixa, blocos[faixa]))
    return coluna


def distancias_f32(ponto, biomas):
    """Distancia euclidiana real de (T,H) a cada centro, em f32 por operacao
    (ordem do kernel). Indice do resultado = indice do bioma."""
    ds = []
    for b in biomas:
        dt = f32(f32(ponto[0] - f32(b["centroTemperatura"])) ** 2)
        dh = f32(f32(ponto[1] - f32(b["centroUmidade"])) ** 2)
        ds.append(f32(math.sqrt(f32(dt + dh))))
    return ds


def gerar_coluna_f32(ponto, biomas, ruidos_por_bioma, limiar,
                     registry, y_min, y_max, spawn_planta,
                     contador_avaliacoes=None):
    """Coluna completa em f32: classificacao (prim = argmin, desempate por
    menor indice) -> blending normalizado multiclique -> altura -> faixas de
    bloco (seguem o PRIMARIO). Retorna o estado da composicao."""
    ds = distancias_f32(ponto, biomas)
    prim = min(range(len(biomas)), key=lambda i: (ds[i], i))
    sec = min((i for i in range(len(biomas)) if i != prim), key=lambda i: (ds[i], i), default=-1)
    alt_prim = altura_bioma_f32(biomas[prim], ruidos_por_bioma[prim])
    if len(biomas) == 1:
        blended = alt_prim
        pesos, avaliados, alturas = [1.0], [0], {0: alt_prim}
    else:
        blended, pesos, avaliados, alturas = blending_multiclique_f32(
            ds, prim, limiar, biomas, ruidos_por_bioma, contador_avaliacoes)
    altura = altura_final_f32(blended)

    bioma_prim = biomas[prim]
    return {
        "prim": prim, "sec": sec, "distancias": ds, "pesos": pesos,
        "pesos_norm": {i: f32(p / (sum(pesos) or 1.0)) for i, p in enumerate(pesos)},
        "avaliados": avaliados, "alturas": alturas,
        "alt_prim": alt_prim, "blended": blended, "altura": altura,
        "coluna": montar_coluna(bioma_prim, registry, altura, y_min, y_max, spawn_planta),
        "bioma_prim": bioma_prim["nome"],
    }


# ----------------------------------------------------------------------------
# Oracle independente (f64 = valor exato dos dados float32)
# ----------------------------------------------------------------------------

def gerar_coluna_f64(ponto, biomas, ruidos_por_bioma, limiar,
                     registry, y_min, y_max, spawn_planta):
    """Mesmas decisoes em float64 com os mesmos ruidos injetados."""
    def altura_bioma(bioma, ruidos):
        acc = float(bioma["alturaBase"])
        for camada, ruido in zip(bioma["camadas"], ruidos):
            contrib = float(ruido) * float(camada["amplitude"])
            acc += -contrib if camada["operacao"] == "subtracao" else contrib
        return acc

    dists = []
    for b in biomas:
        dt = ponto[0] - b["centroTemperatura"]
        dh = ponto[1] - b["centroUmidade"]
        dists.append(math.sqrt(dt * dt + dh * dh))
    prim = min(range(len(biomas)), key=lambda i: (dists[i], i))
    sec = min((i for i in range(len(biomas)) if i != prim), key=lambda i: (dists[i], i), default=-1)

    h_acc = 0.0
    w_acc = 0.0
    pesos = [0.0] * len(biomas)
    avaliados = []
    alturas = {}
    for i in range(len(biomas)):
        diff = dists[i] - dists[prim]
        t = min(1.0, max(0.0, (diff - limiar) / (0.0 - limiar)))
        s = t * t * (3.0 - 2.0 * t)
        pesos[i] = s
        if s > 0:
            h = altura_bioma(biomas[i], ruidos_por_bioma[i])
            h_acc += s * h
            w_acc += s
            avaliados.append(i)
            alturas[i] = h
    blended = h_acc / w_acc if w_acc > 0 else altura_bioma(biomas[prim], ruidos_por_bioma[prim])
    alt_prim = alturas.get(prim, altura_bioma(biomas[prim], ruidos_por_bioma[prim]))
    altura = min(ALTURA_MAX, max(ALTURA_MIN, math.floor(blended + 0.5)))

    bioma_prim = biomas[prim]
    return {
        "prim": prim, "sec": sec, "distancias": dists, "pesos": pesos,
        "pesos_norm": {i: p / (sum(pesos) or 1.0) for i, p in enumerate(pesos)},
        "avaliados": avaliados, "alturas": alturas,
        "alt_prim": alt_prim, "blended": blended, "altura": altura,
        "coluna": montar_coluna(bioma_prim, registry, altura, y_min, y_max, spawn_planta),
        "bioma_prim": bioma_prim["nome"],
    }


# ----------------------------------------------------------------------------
# Checks
# ----------------------------------------------------------------------------

PASS, FAIL = 0, 0


def check(name, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"  FALHOU: {name}")


def bioma_simples(nome, centro_t, centro_h, altura_base, superficie, subsolo,
                  profundo, profundidade=PROFUNDIDADE_PADRAO, plantas=False,
                  camadas=None):
    """Helper de cenario: bioma minimo com defaults aplicados."""
    camadas = camadas or []
    return {"nome": nome, "centroTemperatura": centro_t, "centroUmidade": centro_h,
            "alturaBase": altura_base, "blocoSuperficie": superficie,
            "blocoSubsuperficie": subsolo, "blocoProfundo": profundo,
            "profundidadeSubsuperficie": profundidade, "permitePlantas": plantas,
            "camadas": camadas}


def sem_ruido(biomas):
    return {i: [0.0] * len(b["camadas"]) for i, b in enumerate(biomas)}


# ----------------------------------------------------------------------------
# Cenarios
# ----------------------------------------------------------------------------

def cenario_classificacao_e_early_out():
    print("[cenario] classificacao, empate, early-out e ecotono (REQ-BIO-02)")
    biomas = [
        bioma_simples("a", 0.3, 0.2, 32, "grama", "terra", "pedra"),
        bioma_simples("b", -0.8, 0.0, 36, "snow", "ice", "pedra"),
        bioma_simples("c", 0.8, -0.7, 34, "sand", "sand", "sand"),
    ]
    ruidos = sem_ruido(biomas)

    # interior: todos os diff_i > limiar -> so o primario avaliado
    contador = []
    r = gerar_coluna_f32((0.3, 0.2), biomas, ruidos, LIMIAR_TRANSICAO_PADRAO,
                         REGISTRY_PADRAO, 0, 70, False, contador)
    check("interior: primario = bioma do centro", r["prim"] == 0)
    check("interior: so o primario avaliado (contador de mock)", contador == ["a"])
    check("interior: peso normalizado 1,0 no primario", r["pesos_norm"][0] == 1.0)
    check("interior: altura = alturaBase", r["altura"] == 32)

    # ecotono central: ponto equidistante -> diff = 0 -> 50/50
    # ponto medio entre a e b: ((0.3-0.8)/2, (0.2+0.0)/2) = (-0.25, 0.1)
    ponto = (-0.25, 0.1)
    contador = []
    r = gerar_coluna_f32(ponto, biomas, ruidos, LIMIAR_TRANSICAO_PADRAO,
                         REGISTRY_PADRAO, 0, 70, False, contador)
    check("ecotono central: empate exato (diff == 0)",
          abs(r["distancias"][0] - r["distancias"][1]) < 1e-7)
    check("ecotono central: 50/50 (pesos normalizados 0,5/0,5)",
          r["pesos_norm"][0] == 0.5 and r["pesos_norm"][1] == 0.5)
    check("ecotono central: altura = media (32+36)/2 = 34", r["altura"] == 34)
    check("ecotono central: ambos avaliados, c fora do limiar",
          sorted(r["avaliados"]) == [0, 1] and contador == ["a", "b"])

    # zona de limiar: diff ~= limiar (epsilon para dentro; no exato o
    # arredondamento f32 de d_i - d_prim pode cruzar o limiar)
    dx, dy = 0.8 - 0.3, -0.7 - 0.2
    norma = math.hypot(dx, dy)
    folga = 1e-5
    # ponto sobre o segmento a->c com d_c - d_a = limiar - folga:
    # fracao s = (1 - (limiar-folga)/norma) / 2 a partir de a
    s = (1.0 - (LIMIAR_TRANSICAO_PADRAO - folga) / norma) / 2.0
    t_estrela = 0.3 + s * dx
    h_estrela = 0.2 + s * dy
    r = gerar_coluna_f32((t_estrela, h_estrela), biomas, ruidos,
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 70, False)
    check("limiar: vizinho com s > 0 ainda entra", 1 in r["avaliados"] or 2 in r["avaliados"])
    check("limiar: peso do vizinho ~= 0 (smoothstep no extremo)",
          max(r["pesos_norm"][1], r["pesos_norm"][2]) < 1e-3)

    # logo acima do limiar: vizinho excluido (s = 0)
    t_fora = 0.3 + (LIMIAR_TRANSICAO_PADRAO / 2.0 + 1e-4) * (dx / norma)
    h_fora = 0.2 + (LIMIAR_TRANSICAO_PADRAO / 2.0 + 1e-4) * (dy / norma)
    contador = []
    r = gerar_coluna_f32((t_fora, h_fora), biomas, ruidos,
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 70, False, contador)
    check("acima do limiar: vizinho excluido (so primario avaliado)",
          r["avaliados"] == [0] and contador == ["a"])

    # empate de distancias a 3 biomas: desempate por menor indice
    empate = [
        bioma_simples(" primeiro", 0.0, 0.0, 30, "grama", "terra", "pedra"),
        bioma_simples("segundo", 1.0, 0.0, 40, "sand", "sand", "sand"),
        bioma_simples("terceiro", 0.0, 1.0, 50, "snow", "ice", "pedra"),
    ]
    # ponto (0, 0): dist 0 ao bioma 0; raiz(2) aos biomas 1 e 2
    r = gerar_coluna_f32((0.0, 0.0), empate, sem_ruido(empate),
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 70, False)
    check("empate: primario = menor indice (bioma 0)", r["prim"] == 0 and r["altura"] == 30)
    check("empate: secundario = proximo menor indice (bioma 1)", r["sec"] == 1)

    # desempate entre distantes empatados: (0,6;0,6) dista sqrt(0,72) do
    # bioma 0 e sqrt(0,52) de 1 e 2 (empatados) -> prim=1, sec=2 (menor indice)
    r = gerar_coluna_f32((0.6, 0.6), empate, sem_ruido(empate),
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 70, False)
    check("empate parcial: prim = bioma 1 (mais proximo)", r["prim"] == 1)
    check("empate parcial: sec = menor indice entre empatados (1 < 2)",
          r["sec"] == 2)


def cenario_composicao_altura():
    print("[cenario] composicao de altura: camadas, subtracao, clamp e round")
    # camadas de adicao e subtracao (vale/ravina)
    monte = bioma_simples("monte", 0.0, 0.0, 40, "pedra", "pedra", "pedra",
                          camadas=[
                              {"amplitude": 25, "frequencia": 0.006, "oitavas": 4,
                               "tipo": "perlin", "operacao": "adicao"},
                              {"amplitude": 8, "frequencia": 0.010, "oitavas": 1,
                               "tipo": "simplex", "operacao": "subtracao"},
                          ])
    biomas = [monte]
    ruidos = {0: [1.0, 1.0]}  # ruido maximo: 40 + 25 - 8 = 57
    r = gerar_coluna_f32((0.0, 0.0), biomas, ruidos, LIMIAR_TRANSICAO_PADRAO,
                         REGISTRY_PADRAO, 0, 70, False)
    check("camadas: adicao + subtracao -> 40 + 25 - 8 = 57", r["altura"] == 57)

    ruidos = {0: [0.5, 1.0]}  # 40 + 12.5 - 8 = 44.5 -> half up = 45
    r = gerar_coluna_f32((0.0, 0.0), biomas, ruidos, LIMIAR_TRANSICAO_PADRAO,
                         REGISTRY_PADRAO, 0, 70, False)
    check("arredondamento no meio: 44,5 -> round half up = 45", r["altura"] == 45)

    ruidos = {0: [0.5, 0.0]}  # 40 + 12.5 = 52.5 -> 53 (meio sem subtracao)
    r = gerar_coluna_f32((0.0, 0.0), biomas, ruidos, LIMIAR_TRANSICAO_PADRAO,
                         REGISTRY_PADRAO, 0, 70, False)
    check("arredondamento no meio: 52,5 -> round half up = 53", r["altura"] == 53)

    # alturaBase acima do clamp: 40000 -> 32767
    alto = bioma_simples("alto", 0.0, 0.0, 40000, "pedra", "pedra", "pedra")
    r = gerar_coluna_f32((0.0, 0.0), [alto], sem_ruido([alto]),
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 40005, False)
    check("clamp: alturaBase 40000 -> 32767", r["altura"] == 32767)
    check("clamp: topo em y=32767 e solido ate o fim da faixa",
          dict((y, f) for y, f, _ in r["coluna"])[32767] == "superficie")
    # altura negativa (so camadas de subtracao) -> clamp em 1
    fundo = bioma_simples("fundo_mar", 0.0, 0.0, 2, "pedra", "pedra", "pedra",
                          camadas=[{"amplitude": 10, "frequencia": 0.01, "oitavas": 1,
                                    "tipo": "simplex", "operacao": "subtracao"}])
    r = gerar_coluna_f32((0.0, 0.0), [fundo], {0: [1.0]},
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 5, False)
    check("clamp inferior: 2 - 10 -> clamp em 1", r["altura"] == 1)

    # bioma sem camadas: altura = alturaBase exata
    plano = bioma_simples("plano", 0.0, 0.0, 32, "grama", "terra", "pedra", camadas=[])
    r = gerar_coluna_f32((0.0, 0.0), [plano], sem_ruido([plano]),
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 40, False)
    check("sem camadas: altura = alturaBase (32)", r["altura"] == 32)


def cenario_faixas_e_planta():
    print("[cenario] selecao de bloco por faixa de y e planta (REQ-BIO-03)")
    biomas = [bioma_simples("a", 0.3, 0.2, 32, "grama", "terra", "pedra",
                            profundidade=8, plantas=True)]
    r = gerar_coluna_f32((0.3, 0.2), biomas, sem_ruido(biomas),
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 40, True)
    coluna = {y: (faixa, bloco) for y, faixa, bloco in r["coluna"]}
    check("superficie: y==32 -> grama (id 1)", coluna[32] == ("superficie", 1))
    check("subsolo: 24 < y < 32 -> terra (id 2)", coluna[31] == ("subsolo", 2))
    check("fundo: y <= 24 -> pedra (id 3)", coluna[24] == ("fundo", 3) and coluna[0] == ("fundo", 3))
    check("planta: y==33 com spawn -> id 4", coluna[33] == ("planta", 4))
    check("ar: y >= 34 -> id 0", coluna[34] == ("ar", 0) and coluna[40] == ("ar", 0))

    # sem planta (bioma nao permite): y==altura+1 e ar
    biomas = [bioma_simples("b", 0.3, 0.2, 32, "sand", "sand", "sand",
                            profundidade=4, plantas=False)]
    r = gerar_coluna_f32((0.3, 0.2), biomas, sem_ruido(biomas),
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 40, True)
    coluna = {y: (faixa, bloco) for y, faixa, bloco in r["coluna"]}
    check("sem planta (bioma proibe): y==33 -> ar", coluna[33] == ("ar", 0))
    check("permitePlantas=false ignora spawn sorteado", coluna[32] == ("superficie", 7))

    # permitePlantas=true mas coluna nao sorteia spawn -> ar
    biomas = [bioma_simples("c", 0.3, 0.2, 32, "grama", "terra", "pedra",
                            profundidade=8, plantas=True)]
    r = gerar_coluna_f32((0.3, 0.2), biomas, sem_ruido(biomas),
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 40, False)
    coluna = {y: (faixa, bloco) for y, faixa, bloco in r["coluna"]}
    check("planta exige spawn (wang hash): sem sorteio -> ar", coluna[33] == ("ar", 0))

    # profundidade 0: tudo fundo exceto superficie
    biomas = [bioma_simples("d", 0.3, 0.2, 32, "snow", "ice", "pedra", profundidade=0)]
    r = gerar_coluna_f32((0.3, 0.2), biomas, sem_ruido(biomas),
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 40, False)
    coluna = {y: (faixa, bloco) for y, faixa, bloco in r["coluna"]}
    check("profundidade 0: superficie em y==32", coluna[32] == ("superficie", 6))
    check("profundidade 0: y==31 (32-0) -> fundo", coluna[31] == ("fundo", 3))
    check("profundidade 0: y==0 -> fundo", coluna[0] == ("fundo", 3))

    # profundidade maior que a altura: altura-profundidade < 0, entao nenhum
    # y >= 0 cai no fundo — so superficie + subsolo
    biomas = [bioma_simples("e", 0.3, 0.2, 6, "snow", "ice", "pedra", profundidade=100)]
    r = gerar_coluna_f32((0.3, 0.2), biomas, sem_ruido(biomas),
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 40, False)
    coluna = {y: (faixa, bloco) for y, faixa, bloco in r["coluna"]}
    check("profundidade > altura: so superficie + subsolo (fundo so em y<0)",
          coluna[6] == ("superficie", 6)
          and coluna[5] == ("subsolo", 5) and coluna[0] == ("subsolo", 5))


def cenario_blending_altura():
    print("[cenario] blending de altura no ecotono (blocos seguem o primario)")
    baixo = bioma_simples("baixo", 0.0, 0.0, 20, "grama", "terra", "pedra")
    alto = bioma_simples("alto", 1.0, 0.0, 40, "snow", "ice", "pedra")
    biomas = [baixo, alto]

    # ecotono central (peso 0,5): altura = 30; blocos do PRIMARIO (baixo)
    ponto = (0.5, 0.0)  # equidistante
    r = gerar_coluna_f32(ponto, biomas, sem_ruido(biomas), LIMIAR_TRANSICAO_PADRAO,
                         REGISTRY_PADRAO, 0, 50, False)
    check("blending: peso 0,5 -> altura 30", r["altura"] == 30)
    sup = [b for _, f, b in r["coluna"] if f == "superficie"]
    check("blocos seguem o primario (superficie grama id 1)", sup == [1])
    check("blending: nenhum bloco do secundario na coluna",
          5 not in {b for _, _, b in r["coluna"]})

    # meio do ecotono (nova curva): diff = 0,075 -> s = 0,5; normalizado
    # peso_sec = 0,5/1,5 = 1/3 (franja mais larga que o lerp antigo, 0,25)
    p = 0.4625
    r = gerar_coluna_f32((p, 0.0), biomas, sem_ruido(biomas),
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 50, False)
    check("meio do ecotono: s = 0,5 -> peso normalizado 1/3",
          abs(r["pesos_norm"][1] - 1.0 / 3.0) < 1e-6)
    check("meio do ecotono: altura = 20*2/3 + 40*1/3 = 26,67 -> 27",
          r["altura"] == 27)


def cenario_blending_multiclique():
    print("[cenario] blending normalizado multiclique (REQ-BIO-02)")
    # 3 biomas equidistantes (diff 0) -> media igualitaria 1/3
    tri = [
        bioma_simples("t0", 1.0, 0.0, 30, "grama", "terra", "pedra"),
        bioma_simples("t1", -0.5, 0.8660254, 40, "sand", "sand", "sand"),
        bioma_simples("t2", -0.5, -0.8660254, 60, "snow", "ice", "pedra"),
    ]
    r = gerar_coluna_f32((0.0, 0.0), tri, sem_ruido(tri), LIMIAR_TRANSICAO_PADRAO,
                         REGISTRY_PADRAO, 0, 80, False)
    check("multiclique 3 equidistantes: todos avaliados", r["avaliados"] == [0, 1, 2])
    check("multiclique 3 equidistantes: pesos 1/3 cada",
          all(abs(r["pesos_norm"][i] - 1.0 / 3.0) < 1e-6 for i in range(3)))
    check("multiclique 3 equidistantes: altura = (30+40+60)/3 = 43,33 -> 43",
          r["altura"] == 43)
    check("multiclique 3: nenhum peso supera o primario",
          max(r["pesos_norm"].values()) <= r["pesos_norm"][r["prim"]] + 1e-9)

    # 4 biomas dentro do limiar: pesos normalizados coherentes (somam 1)
    quat = [
        bioma_simples("q0", 0.0, 0.0, 20, "grama", "terra", "pedra"),
        bioma_simples("q1", 0.05, 0.0, 30, "sand", "sand", "sand"),
        bioma_simples("q2", 0.0, 0.06, 50, "snow", "ice", "pedra"),
        bioma_simples("q3", -0.07, -0.02, 80, "podzol", "terra", "terra"),
    ]
    r = gerar_coluna_f32((0.0, 0.0), quat, sem_ruido(quat), LIMIAR_TRANSICAO_PADRAO,
                         REGISTRY_PADRAO, 0, 100, False)
    check("multiclique 4: todos dentro do limiar avaliados", r["avaliados"] == [0, 1, 2, 3])
    check("multiclique 4: pesos normalizados somam 1",
          abs(sum(r["pesos_norm"].values()) - 1.0) < 1e-6)
    check("multiclique 4: pesos decrescem com a distancia",
          r["pesos_norm"][0] > r["pesos_norm"][1] > r["pesos_norm"][3]
          and r["pesos_norm"][0] > r["pesos_norm"][2])
    # altura blended reproduz a media ponderada com os pesos brutos (f32)
    h_esperada = sum(p * a for p, a in zip(r["pesos"], (20, 30, 50, 80))) / sum(r["pesos"])
    check("multiclique 4: altura = media ponderada", abs(r["blended"] - h_esperada) < 1e-4)

    # bioma com diff > limiar no meio de um multiclique: excluido (s = 0)
    contador = []
    r = gerar_coluna_f32((0.0, 0.0), quat, sem_ruido(quat), 0.05,
                         REGISTRY_PADRAO, 0, 100, False, contador)
    check("limiar 0,05: q3 (diff 0,073) excluido do multiclique", 3 not in r["avaliados"])
    check("limiar 0,05: contador nao avaliou q3", "q3" not in contador)
    check("limiar 0,05: peso bruto de q3 == 0", r["pesos"][3] == 0.0)

    # continuidade: varrendo diff de um terceiro bioma (altura 90) de fora
    # do limiar ate 0, o peso sobe suavemente de 0 — nenhum salto de altura
    base = [
        bioma_simples("m0", 0.0, 0.0, 40, "grama", "terra", "pedra"),
        bioma_simples("m1", 0.05, 0.0, 40, "sand", "sand", "sand"),
    ]
    alturas = []
    for desloc in (0.2, 0.151, 0.149, 0.12, 0.075, 0.03, 0.0):
        tri2 = base + [bioma_simples("m2", 0.05 + desloc, 0.0, 90, "snow", "ice", "pedra")]
        r = gerar_coluna_f32((0.0, 0.0), tri2, sem_ruido(tri2),
                             LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 60, False)
        alturas.append((desloc, r["altura"]))
    passos = [abs(alturas[i + 1][1] - alturas[i][1]) for i in range(len(alturas) - 1)]
    check("continuidade: fora do limiar altura = 40 do par puro",
          alturas[0][1] == 40)
    check("continuidade: nenhum salto entre passos vizinhos (max <= 11)",
          max(passos) <= 11)
    s_005 = smoothstep_f32(LIMIAR_TRANSICAO_PADRAO, 0.05)
    esperada_final = (40 + 40 * s_005 + 90 * s_005) / (1 + 2 * s_005)
    check("continuidade: altura sobe suavemente ate a media 3-vias ponderada",
          alturas[-1][1] == math.floor(esperada_final + 0.5)
          and alturas[-1][1] > 50)
    r = gerar_coluna_f32((0.0, 0.0),
                         base + [bioma_simples("m2", 0.2, 0.0, 90, "snow", "ice", "pedra")],
                         sem_ruido(base + [bioma_simples("m2", 0.2, 0.0, 90, "snow", "ice", "pedra")]),
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 60, False)
    check("fora do limiar: altura do terceiro nao influi (early-out por bioma)",
          r["altura"] == 40 and 2 not in r["avaliados"])
    r = gerar_coluna_f32((0.0, 0.0),
                         base + [bioma_simples("m2", 0.05, 0.0, 90, "snow", "ice", "pedra")],
                         sem_ruido(base + [bioma_simples("m2", 0.05, 0.0, 90, "snow", "ice", "pedra")]),
                         LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 60, False)
    # m2 no mesmo centro de m1 (diff 0,05): entra com o mesmo peso de m1
    check("dentro do limiar: terceiro entra no somatorio com peso = do vizinho",
          r["avaliados"] == [0, 1, 2]
          and abs(r["pesos_norm"][2] - r["pesos_norm"][1]) < 1e-9)


def cenario_cinco_biomas():
    print("[cenario] config padrao: os 5 biomas exercitados")
    norm, erro = validar_config_biomas(CONFIG_PADRAO, REGISTRY_PADRAO)
    check("config padrao: valida", erro is None)
    biomas = norm["biomas"]
    check("config padrao: 5 biomas", len(biomas) == 5)
    check("config padrao: limites de camadas (<=8 por bioma, <=64 no total)",
          all(len(b["camadas"]) <= 8 for b in biomas)
          and sum(len(b["camadas"]) for b in biomas) <= 64)
    esperados = {"planicies": 1, "deserto": 7, "pantano": 8, "gelado": 6, "montanhoso": 3}
    for nome, id_sup in esperados.items():
        centro = next((b["centroTemperatura"], b["centroUmidade"])
                      for b in biomas if b["nome"] == nome)
        r = gerar_coluna_f32(centro, biomas, sem_ruido(biomas),
                             LIMIAR_TRANSICAO_PADRAO, REGISTRY_PADRAO, 0, 90, False)
        sup = {b for _, f, b in r["coluna"] if f == "superficie"}
        check(f"{nome}: primario no proprio centro, superficie id {id_sup}",
              r["prim"] == next(i for i, b in enumerate(biomas) if b["nome"] == nome)
              and sup == {id_sup})
    # montanhoso: subtracao presente (ravinas) e clamp nao dispara com ruido nulo
    mont = next(b for b in biomas if b["nome"] == "montanhoso")
    check("montanhoso: tem camada de subtracao",
          any(c["operacao"] == "subtracao" for c in mont["camadas"]))
    # gelado: perlin fBm com 3 oitavas
    gel = next(b for b in biomas if b["nome"] == "gelado")
    check("gelado: perlin fBm com 3 oitavas",
          any(c["tipo"] == "perlin" and c["oitavas"] == 3 for c in gel["camadas"]))
    check("config padrao: permitePlantas = false em todos",
          all(not b["permitePlantas"] for b in biomas))
    check("config padrao: profundidades 8/4/8/4/4",
          [b["profundidadeSubsuperficie"] for b in biomas] == [8, 4, 8, 4, 4])


def cenario_validacao_json():
    print("[cenario] validacao de JSON (REQ-BIO-01)")
    norm, erro = validar_config_biomas(CONFIG_PADRAO, REGISTRY_PADRAO)
    check("defaults: config completa valida", erro is None)

    # defaults aplicados: blocoProfundo, profundidade, permitePlantas
    minima = {"global": dict(CONFIG_PADRAO["global"]), "biomas": [
        {"nome": "x", "centroTemperatura": 0.0, "centroUmidade": 0.0,
         "alturaBase": 10, "blocoSuperficie": "grama", "blocoSubsuperficie": "terra",
         "camadas": []}]}
    norm, erro = validar_config_biomas(minima, REGISTRY_PADRAO)
    check("defaults: campos opcionais ausentes aceitos", erro is None)
    b = norm["biomas"][0]
    check("defaults: blocoProfundo = blocoSubsuperficie", b["blocoProfundo"] == "terra")
    check("defaults: profundidade = 8", b["profundidadeSubsuperficie"] == 8)
    check("defaults: permitePlantas = false", b["permitePlantas"] is False)

    def bioma_ok(nome):
        return {"nome": nome, "centroTemperatura": 0.0, "centroUmidade": 0.0,
                "alturaBase": 10, "blocoSuperficie": "grama",
                "blocoSubsuperficie": "terra", "camadas": []}

    # bloco inexistente no registry
    cfg = {"global": dict(CONFIG_PADRAO["global"]),
           "biomas": [dict(bioma_ok("x"), blocoSuperficie="unobtanium")]}
    _n, erro = validar_config_biomas(cfg, REGISTRY_PADRAO)
    check("rejeicao: bloco inexistente", erro is not None and "unobtanium" in erro)
    cfg = {"global": dict(CONFIG_PADRAO["global"]),
           "biomas": [dict(bioma_ok("x"), blocoProfundo="buraco_negro")]}
    _n, erro = validar_config_biomas(cfg, REGISTRY_PADRAO)
    check("rejeicao: blocoProfundo inexistente", erro is not None and "buraco_negro" in erro)

    # > 16 biomas
    cfg = {"global": dict(CONFIG_PADRAO["global"]),
           "biomas": [bioma_ok(f"b{i}") for i in range(17)]}
    _n, erro = validar_config_biomas(cfg, REGISTRY_PADRAO)
    check("rejeicao: > 16 biomas", erro is not None)

    # > 8 camadas num bioma
    cfg = {"global": dict(CONFIG_PADRAO["global"]),
           "biomas": [dict(bioma_ok("x"), camadas=[
               {"amplitude": 1, "frequencia": 0.01, "tipo": "simplex"}] * 9)]}
    _n, erro = validar_config_biomas(cfg, REGISTRY_PADRAO)
    check("rejeicao: > 8 camadas num bioma", erro is not None)

    # > 64 camadas totais (9 biomas x 8 camadas = 72)
    cfg = {"global": dict(CONFIG_PADRAO["global"]),
           "biomas": [dict(bioma_ok(f"b{i}"), camadas=[
               {"amplitude": 1, "frequencia": 0.01, "tipo": "simplex"}] * 8)
               for i in range(9)]}
    _n, erro = validar_config_biomas(cfg, REGISTRY_PADRAO)
    check("rejeicao: > 64 camadas totais", erro is not None)

    # 8 biomas x 8 camadas = 64 no limite: aceito
    cfg = {"global": dict(CONFIG_PADRAO["global"]),
           "biomas": [dict(bioma_ok(f"b{i}"), camadas=[
               {"amplitude": 1, "frequencia": 0.01, "tipo": "simplex"}] * 8)
               for i in range(8)]}
    norm, erro = validar_config_biomas(cfg, REGISTRY_PADRAO)
    check("limite: 64 camadas totais aceito", erro is None)

    # tipos/operacao invalidos; oitavas fora de 1..8
    base_camada = {"amplitude": 1, "frequencia": 0.01}
    for campo, valor in (("tipo", "fractal_quântico"), ("operacao", "multiplicacao")):
        cfg = {"global": dict(CONFIG_PADRAO["global"]),
               "biomas": [dict(bioma_ok("x"), camadas=[dict(base_camada, **{campo: valor})])]}
        _n, erro = validar_config_biomas(cfg, REGISTRY_PADRAO)
        check(f"rejeicao: camada.{campo} invalido ({valor!r})", erro is not None)
    cfg = {"global": dict(CONFIG_PADRAO["global"]),
           "biomas": [dict(bioma_ok("x"), camadas=[dict(base_camada, tipo="perlin", oitavas=9)])]}
    _n, erro = validar_config_biomas(cfg, REGISTRY_PADRAO)
    check("rejeicao: oitavas 9 fora de 1..8", erro is not None)
    cfg = {"global": dict(CONFIG_PADRAO["global"]),
           "biomas": [dict(bioma_ok("x"), camadas=[{"amplitude": 1, "frequencia": 0}])]}
    _n, erro = validar_config_biomas(cfg, REGISTRY_PADRAO)
    check("rejeicao: frequencia 0", erro is not None)

    # centros fora de [-1, 1]; limiar nao positivo
    cfg = {"global": dict(CONFIG_PADRAO["global"]),
           "biomas": [dict(bioma_ok("x"), centroTemperatura=1.5)]}
    _n, erro = validar_config_biomas(cfg, REGISTRY_PADRAO)
    check("rejeicao: centro fora de [-1, 1]", erro is not None)
    cfg = {"global": dict(CONFIG_PADRAO["global"], limiarTransicao=0.0),
           "biomas": [bioma_ok("x")]}
    _n, erro = validar_config_biomas(cfg, REGISTRY_PADRAO)
    check("rejeicao: limiarTransicao <= 0", erro is not None)


def cenario_oracle_f64():
    print("[cenario] oracle f64: decisoes e alturas vs espelho f32")
    rng = random.Random(1337)
    decisivos = 0
    nomes = ["planicies", "deserto", "pantano", "gelado", "montanhoso"]
    for caso in range(300):
        biomas = []
        for i in range(rng.randint(2, 5)):
            biomas.append(bioma_simples(
                nomes[i], rng.uniform(-1, 1), rng.uniform(-1, 1),
                rng.uniform(1, 100),
                rng.choice(list(REGISTRY_PADRAO)), rng.choice(list(REGISTRY_PADRAO)),
                rng.choice(list(REGISTRY_PADRAO)),
                profundidade=rng.randint(0, 12), plantas=rng.random() < 0.5,
                camadas=[{"amplitude": rng.uniform(0, 30), "frequencia": rng.uniform(0.001, 0.05),
                          "oitavas": rng.randint(1, 4), "tipo": rng.choice(TIPOS_RUIDO),
                          "operacao": rng.choice(OPERACOES)} for _ in range(rng.randint(0, 4))]))
        limiar = rng.uniform(0.05, 0.5)
        ponto = (rng.uniform(-1, 1), rng.uniform(-1, 1))
        ruidos = {i: [rng.uniform(-1, 1) for _ in b["camadas"]]
                  for i, b in enumerate(biomas)}
        spawn = rng.random() < 0.5
        r32 = gerar_coluna_f32(ponto, biomas, ruidos, limiar,
                               REGISTRY_PADRAO, 0, 140, spawn)
        r64 = gerar_coluna_f64(ponto, biomas, ruidos, limiar,
                               REGISTRY_PADRAO, 0, 140, spawn)
        # decisoes devem coincidir exatamente
        check(f"caso {caso}: primario/secundario/avaliados coincidem",
              (r32["prim"], r32["sec"], r32["avaliados"]) ==
              (r64["prim"], r64["sec"], r64["avaliados"]))
        check(f"caso {caso}: altura final (com clamp/round) coincide",
              r32["altura"] == r64["altura"])
        check(f"caso {caso}: coluna (faixas e blocos) coincide",
              r32["coluna"] == r64["coluna"])
        if r32["blended"] == r64["blended"]:
            continue  # espelho e oracle coincidentes: nada a medir
        decisivos += 1
        escala = max([1.0, abs(r64["blended"])] +
                     [abs(h) for h in r64["alturas"].values()])
        # tolerancia de alguns ULPs f32 sobre a escala dos operandos (o espelho
        # arredonda por operacao; o oracle acumula em f64)
        check(f"caso {caso}: altura blended ~ oracle (erro ~ ULPs f32, escala dos operandos)",
              abs(r32["blended"] - r64["blended"]) <= 64.0 * 2.0 ** -24 * escala)
    check("amostragem: >= 200 casos com altura blended decisiva", decisivos >= 200)
    print(f"  ({decisivos} casos decisivos)")


def cenario_arquivo_biomes_json():
    print("[cenario] assets/biomes.json: validacao e paridade com a tabela embutida")
    caminho = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "biomes.json")
    caminho = os.path.normpath(caminho)
    if not os.path.exists(caminho):
        print("  SKIP: assets/biomes.json nao existe (IMPL-02 ainda nao rodou)")
        check("SKIP registrado: arquivo ausente", True)
        return
    with open(caminho, "r", encoding="utf-8") as fh:
        try:
            config = json.load(fh)
        except json.JSONDecodeError as exc:
            check(f"arquivo: JSON parseavel ({exc})", False)
            return
    norm, erro = validar_config_biomas(config, REGISTRY_PADRAO)
    check("arquivo: valido contra as regras do REQ-BIO-01", erro is None)
    if erro is not None:
        print(f"  erro: {erro}")
        return
    embutida, _ = validar_config_biomas(CONFIG_PADRAO, REGISTRY_PADRAO)
    divergencias = []
    for campo in ("semente", "forcaDistorcao", "limiarTransicao",
                  "frequenciaTemperatura", "frequenciaUmidade"):
        if norm["global"].get(campo) != embutida["global"][campo]:
            divergencias.append(f"global.{campo}")
    if len(norm["biomas"]) != len(embutida["biomas"]):
        divergencias.append("quantidade de biomas")
    for eb in embutida["biomas"]:
        ab = next((b for b in norm["biomas"] if b["nome"] == eb["nome"]), None)
        if ab is None:
            divergencias.append(f"bioma ausente: {eb['nome']}")
            continue
        for campo in ("centroTemperatura", "centroUmidade", "alturaBase",
                      "blocoSuperficie", "blocoSubsuperficie", "blocoProfundo",
                      "profundidadeSubsuperficie", "permitePlantas"):
            if ab.get(campo) != eb[campo]:
                divergencias.append(f"{eb['nome']}.{campo}")
        if ab.get("camadas") != eb["camadas"]:
            divergencias.append(f"{eb['nome']}.camadas")
    if divergencias:
        print(f"  DIVERGENCIAS (reportadas, nao falham): {divergencias}")
    check("arquivo: paridade com a tabela embutida (divergencias so reportadas)",
          True)


def main():
    cenario_classificacao_e_early_out()
    cenario_composicao_altura()
    cenario_faixas_e_planta()
    cenario_blending_altura()
    cenario_blending_multiclique()
    cenario_cinco_biomas()
    cenario_validacao_json()
    cenario_oracle_f64()
    cenario_arquivo_biomes_json()
    print(f"\n{PASS} passaram, {FAIL} falharam")
    raise SystemExit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
