#!/usr/bin/env python3
"""
i18n-audit.py — Carry 本地化（xcstrings）全目录审计。

为什么存在：本项目曾积累约 2000+ 条「看不见的」本地化缺陷——大量字符串只翻了
en/中文，其余 6 语言以英文原文 + `needs_review` 状态躺着；另有计数文案一律用扁平
`%lld`、从不用复数变体（count=1 显 "1 trips"）。这些在「只用英文/中文设备测试」时
完全不可见。本脚本把这些信号变成可被机器检出的硬指标，让「同步补全所有语言」这条
规范可被强制，而不是靠人记得。

检出（默认两个目录都查）：
  [E] needs_review        某语言 state != translated —— 等于「未翻译」（Xcode 自动把
                          新增英文复制到各语言并标 needs_review，不手动翻就一直是它）
  [E] missing             某语言条目完全缺失
  [W] leftover-en (CJK)   zh/ja/ko 值仍是纯拉丁英文（疑似漏译；品牌/技术词除外）
  [W] zh half-width punct  中文值里中文相邻处用了英文半角标点（应全角）
  [I] plural-candidate    扁平 `%lld`/`%d` + 紧邻名词，可能需要复数变体（建议人工复核；
                          已 gate(≥2)/硬编码/序数/年份/缩写单位的属误报）

用法：
  python3 scripts/i18n-audit.py                 # 查全部，有 [E] 则退出码 1
  python3 scripts/i18n-audit.py --strict        # 有 [E] 或 [W] 都退出码 1
  python3 scripts/i18n-audit.py --plural        # 额外列出复数候选（默认不列，噪声大）

约定：`shouldTranslate: false` 的 key 跳过；纯格式/符号/品牌键不应报 leftover-en。
"""
import json, re, sys, os

LANGS = ['de', 'es', 'fr', 'ja', 'ko', 'pt-BR', 'zh-Hans', 'zh-Hant']
CJK = ['ja', 'ko', 'zh-Hans', 'zh-Hant']
CATALOGS = ['Carry/Localizable.xcstrings', 'CarryWidget/Localizable.xcstrings']
# 允许 CJK 值保持拉丁原文的键（品牌/专有名词/人名/技术框架名/地图 App）
BRAND_OK = re.compile(r'^(Carry|Murphy|Mapbox|Geoapify|OpenFlights|OpenStreetMap|'
                      r'OurAirports|Wikidata|StoreKit|StoreKit not ready|Twitter / X|'
                      r'Made with|Mock|Amap|Baidu Maps|Apple Maps|Google Maps|Waze)$')
# DEBUG/开发者键：不发版给普通用户，漏译不计
DEBUG_KEY = re.compile(r'^(debug\.|settings\.debug\.|settings\.mock\.|settings\.developer\.)')
# 纯占位符/格式示例（全大写+数字+符号），如 ABC / ABC123 / (XXX) XXX-XXXX / ABC·1234 / A320
PLACEHOLDER = re.compile(r'^[A-Z0-9 ()·\-+#./]+$')


def strip_fmt(s):
    return re.sub(r'%\d*\$?l*[d@]|%%', '', s)


def is_symbol(s):
    return not re.search(r'[A-Za-zÀ-ɏ一-鿿぀-ヿ가-힣]', strip_fmt(s))


def leaf_states(lv):
    out = []
    su = lv.get('stringUnit')
    if su:
        out.append(su.get('state'))
    for sd in lv.get('substitutions', {}).values():
        for cv in sd.get('variations', {}).get('plural', {}).values():
            out.append(cv.get('stringUnit', {}).get('state'))
    for cv in lv.get('variations', {}).get('plural', {}).values():
        out.append(cv.get('stringUnit', {}).get('state'))
    return [s for s in out if s is not None]


def flat_value(lv):
    return lv.get('stringUnit', {}).get('value')


def en_source(key, v):
    en = v.get('localizations', {}).get('en', {}).get('stringUnit', {}).get('value')
    return en if en is not None else key  # 语义键：key 即英文


def audit(path):
    errs, warns, infos = [], [], []
    with open(path, encoding='utf-8') as f:
        d = json.load(f)['strings']
    for key, v in d.items():
        if v.get('shouldTranslate') is False:
            continue
        locs = v.get('localizations', {})
        en = en_source(key, v)
        # 复数候选（仅 en 源含「数字占位符 + 紧邻字母词」）
        if re.search(r'%\d*\$?l*[d]\s*[A-Za-z]', en) or re.search(r'[A-Za-z]\s*%\d*\$?l*[d]\b', en):
            infos.append((key, 'plural-candidate', 'en', en[:50]))
        for l in LANGS:
            lv = locs.get(l)
            if lv is None:
                errs.append((key, 'missing', l, ''))
                continue
            st = leaf_states(lv)
            if any(s != 'translated' for s in st):
                errs.append((key, 'needs_review', l, (flat_value(lv) or '')[:50]))
                continue
            val = flat_value(lv)
            if val is None:  # 复数变体键，无扁平值，跳过后续逐值检查
                continue
            if en.strip().startswith('http') or val.startswith('http'):
                continue  # URL：不做漏译/标点检查
            # leftover English（CJK 仍是纯拉丁）—— 跳过 DEBUG 键、品牌、纯占位符、符号
            if (l in CJK and not DEBUG_KEY.match(key) and not BRAND_OK.match(en.strip())
                    and not PLACEHOLDER.match(en.strip()) and not is_symbol(en)):
                if not re.search(r'[一-鿿぀-ヿ가-힣]', val) and re.search(r'[A-Za-z]{3,}', val):
                    warns.append((key, 'leftover-en', l, val[:50]))
            # 中文半角标点
            if l.startswith('zh'):
                if re.search(r'(?<=[一-鿿])[,;:?!]', val) or re.search(r'[,;:?!](?=[一-鿿])', val) or '...' in val:
                    warns.append((key, 'zh-halfwidth-punct', l, val[:50]))
    return errs, warns, infos


def main():
    strict = '--strict' in sys.argv
    show_plural = '--plural' in sys.argv
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)
    total_e = total_w = 0
    for cat in CATALOGS:
        if not os.path.exists(cat):
            continue
        errs, warns, infos = audit(cat)
        total_e += len(errs)
        total_w += len(warns)
        print(f'\n=== {cat} ===')
        print(f'  [E] errors: {len(errs)}   [W] warnings: {len(warns)}   '
              f'[I] plural-candidates: {len(infos)}')
        for k, kind, l, val in errs[:60]:
            print(f'    [E] {kind:13} {l:8} {k[:40]!r} {val}')
        if len(errs) > 60:
            print(f'    … +{len(errs)-60} more errors')
        for k, kind, l, val in warns[:40]:
            print(f'    [W] {kind:18} {l:8} {k[:40]!r} {val}')
        if show_plural:
            for k, kind, l, val in infos:
                print(f'    [I] {kind:18} {k[:40]!r} {val}')
    print(f'\nTOTAL: {total_e} errors, {total_w} warnings')
    if total_e or (strict and total_w):
        sys.exit(1)


if __name__ == '__main__':
    main()
