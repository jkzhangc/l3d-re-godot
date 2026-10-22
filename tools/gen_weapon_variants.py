#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按原作 weapon.html 补齐武器变种（数据级）+ 强化道具。

只改数值/名称：贴图、动作表、子弹、特效、枪口偏移全部沿用同类别的基础武器
（原作同类别武器也是同一套贴图，只差数值），因此不新增美术资源。

跳过「近接武器」——用户明确说近战先不做。

运行：python tools/gen_weapon_variants.py
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OBJ = ROOT / 'object'

# 基础武器 → 新变种
# 字段：id, 名称, 威力, 射程, 弹匣, 备弹, 攻速倍率, 说明
VARIANTS = {
    'weapon_pistol.tres': [
        ('pistol_02', 'S&W M36 左轮', 33, 184, 6, 24, 0.85,
         '原作 ハンドガン/S&W M36（威力20／连射C／射程C）。左轮，射速偏慢但单发更重。'),
        ('pistol_03', 'FN-57 手枪', 25, 200, 20, 30, 1.0,
         '原作 ハンドガン/FN-57（威力15／连射C／射程B）。弹匣大，续航好。'),
        ('pistol_04', '贝雷塔 M93R', 25, 200, 20, 30, 1.25,
         '原作 ハンドガン/ﾍﾞﾚｯﾀM93R（威力15／连射B）。三连发点射，射速更快。'),
    ],
    'weapon_smg.tres': [
        ('smg_02', 'Vz61 蝎式', 23, 190, 20, 300, 1.1,
         '原作 ｻﾌﾞﾏｼﾝｶﾞﾝ/Vz61（威力15／连射A）。轻小、弹匣少，撒得快。'),
        ('smg_03', 'FN-P90', 27, 200, 50, 300, 1.05,
         '原作 ｻﾌﾞﾏｼﾝｶﾞﾝ/FN-P90（威力18／连射A）。50 发大弹匣，压制力强。'),
        ('smg_04', 'MP5', 30, 200, 30, 300, 1.0,
         '原作 ｻﾌﾞﾏｼﾝｶﾞﾝ/MP5（威力20／连射A）。均衡型冲锋枪。'),
    ],
    'weapon_rifle.tres': [
        ('rifle_02', 'AK-47', 23, 200, 30, 350, 1.0,
         '原作 ｱｻﾙﾄﾗｲﾌﾙ/AK-47（威力20／连射B）。备弹多、单发偏低。'),
        ('rifle_03', 'M4-A1', 35, 200, 30, 270, 1.05,
         '原作 ｱｻﾙﾄﾗｲﾌﾙ/M4-A1（威力30／连射B）。精度与威力均衡。'),
        ('rifle_04', 'FA-MAS', 29, 200, 25, 230, 1.15,
         '原作 ｱｻﾙﾄﾗｲﾌﾙ/FA-MAS（威力25／连射A）。射速快、备弹少。'),
        ('rifle_05', 'M249 轻机枪', 52, 220, 100, 300, 1.2,
         '原作 軽機関銃/M249（威力45／连射A）。100 发弹链，站桩压制用，移动射击代价高。'),
    ],
    'weapon_shotgun.tres': [
        ('shotgun_02', '贝内利 M4', 39, 200, 6, 270, 1.15,
         '原作 ショットガン/ﾍﾞﾈﾘM4（威力35／连射C）。半自动霰弹枪，比 M870 快。'),
        ('shotgun_03', 'Striker', 34, 200, 8, 330, 1.3,
         '原作 ショットガン/Striker（威力30／连射B）。弹鼓供弹，连喷最快。'),
    ],
    'weapon_sniper.tres': [
        ('sniper_02', '德拉贡诺夫', 37, 300, 10, 130, 1.1,
         '原作 ｽﾅｲﾊﾟｰﾗｲﾌﾙ/ﾄﾞﾗｸﾞﾉﾌ（威力100／连射D(C)）。半自动狙击，出手更快、威力略低。'),
        ('sniper_03', 'H&K PSG1', 44, 300, 10, 120, 1.1,
         '原作 ｽﾅｲﾊﾟｰﾗｲﾌﾙ/H&K PSG1（威力120／连射D(C)）。介于 M700 与德拉贡诺夫之间。'),
        ('sniper_04', '巴雷特 M82', 110, 320, 10, 50, 0.8,
         '原作 対戦車ﾗｲﾌﾙ/ﾊﾞﾚｯﾄM82（威力300／连射D）。反器材步枪，单发极高、射速最慢。'),
    ],
    'weapon_magnum.tres': [
        ('magnum_02', '沙漠之鹰', 80, 260, 7, 60, 1.0,
         '原作 マグナム/ﾃﾞｻﾞｰﾄｲｰｸﾞﾙ（威力80／连射C）。威力略低、备弹更多。'),
        ('magnum_03', 'Endfield', 120, 260, 6, 45, 1.0,
         '原作 マグナム/ｴﾝﾄﾞﾌｨｰﾙﾄﾞ（威力120／连射C）。单发最高、备弹最少。'),
    ],
    'weapon_grenade_launcher.tres': [
        ('launcher_02', 'Denel-MGL', 100, 240, 1, 60, 1.2,
         '原作 Ｇﾗﾝﾁｬｰ/Denel-MGL（威力100／连射C）。多管榴弹发射器，射速更快、单发略低。'),
    ],
    'weapon_rocket_launcher.tres': [
        ('rocket_02', 'M202 四联火箭', 300, 280, 1, 40, 1.0,
         '原作 Ｒランチャー/M202（威力300／连射D）。备弹更多。'),
        ('rocket_03', '便携式地对空导弹', 300, 320, 1, 20, 1.0,
         '原作 携帯式地対空ミサイル（威力300／连射D）。射程更远。'),
    ],
}

# 角色白名单要追加的 id（主武器 / 副武器）
PRIMARY_NEW = ['rifle_02', 'rifle_03', 'rifle_04', 'rifle_05', 'shotgun_02', 'shotgun_03',
               'smg_02', 'smg_03', 'smg_04', 'sniper_02', 'sniper_03', 'sniper_04',
               'launcher_02', 'rocket_02', 'rocket_03']
SECONDARY_NEW = ['pistol_02', 'pistol_03', 'pistol_04', 'magnum_02', 'magnum_03']


def set_field(text, key, value):
    """替换 `key = ...` 一行；没有该行就插到 attack_power 之后。"""
    pat = re.compile(r'^%s = .*$' % re.escape(key), re.M)
    line = '%s = %s' % (key, value)
    if pat.search(text):
        return pat.sub(line, text, count=1)
    anchor = re.search(r'^attack_power = .*$', text, re.M)
    if anchor:
        return text[:anchor.end()] + '\n' + line + text[anchor.end():]
    raise SystemExit('找不到插入点：' + key)


def scale_frame_durations(text, speed):
    """攻速倍率落到**帧时长**上（单机射速由攻击动画时长决定；attack_speed 只有联机补发用）。

    基础武器大多没写 `attack_frame_durations`（走 WeaponData 默认：每帧 0.1s × 4 帧），
    这种情况下按同样长度补一份显式数组，否则倍率在单机里完全不生效。
    """
    if abs(speed - 1.0) < 0.001:
        return text
    pat = re.compile(r'^attack_frame_durations = Array\[float\]\(\[(.*?)\]\)$', re.M)
    m = pat.search(text)
    if m is None or not m.group(1).strip():
        vals = [0.1, 0.1, 0.1, 0.1]
        line = 'attack_frame_durations = Array[float]([%s])' % \
               ', '.join('%.3f' % max(0.02, v / speed) for v in vals)
        anchor = re.search(r'^attack_char_sequence = .*$', text, re.M)
        if anchor is None:
            anchor = re.search(r'^attack_range = .*$', text, re.M)
        if anchor is None:
            raise SystemExit('找不到 attack_frame_durations 的插入点')
        return text[:anchor.end()] + '\n' + line + text[anchor.end():]
    vals = [float(v) for v in m.group(1).split(',')]
    scaled = ', '.join('%.3f' % max(0.02, v / speed) for v in vals)
    line = 'attack_frame_durations = Array[float]([%s])' % scaled
    return text[:m.start()] + line + text[m.end():]


def make_variant(base_name, vid, name, power, rng, mag, reserve, speed, desc):
    base = (OBJ / base_name).read_text(encoding='utf-8')
    # 去掉 uid，避免与新资源冲突（Godot 会在保存时重新分配）
    out = re.sub(r'^\[gd_resource ([^\]]*?) uid="[^"]*"', r'[gd_resource \1', base, count=1, flags=re.M)
    out = set_field(out, 'attack_power', power)
    out = set_field(out, 'attack_range', '%.1f' % rng)
    out = set_field(out, 'magazine_capacity', mag)
    out = set_field(out, 'initial_reserve_ammo', reserve)
    out = set_field(out, 'attack_speed', '%.2f' % speed)
    out = scale_frame_durations(out, speed)
    out = set_field(out, 'item_id', '"%s"' % vid)
    out = set_field(out, 'item_name', '"%s"' % name)
    out = set_field(out, 'description', '"%s"' % desc)
    path = OBJ / ('weapon_%s.tres' % vid)
    path.write_text(out, encoding='utf-8', newline='\n')
    return path


def main():
    made = []
    for base, items in VARIANTS.items():
        for row in items:
            made.append(make_variant(base, *row))

    # ── 强化道具（原作 weapon.html 強化アイテム）──
    item_tpl = '''[gd_resource type="Resource" script_class="ItemData" load_steps=2 format=3]

[ext_resource type="Script" path="res://script/item_data.gd" id="1"]

[resource]
script = ExtResource("1")
item_id = "%s"
item_name = "%s"
item_type = 7
description = "%s"
effect_text = "%s"
sell_price = %d
stackable = true
max_stack = 5
%s
'''
    (OBJ / 'item_painkiller.tres').write_text(item_tpl % (
        'painkiller_01', '镇痛剂',
        '原作 強化アイテム/鎮痛剤。短时间内完全免疫伤害，但 Heat/削り/Push 等状态照常生效。',
        '15 秒内受到的伤害为 0', 80, 'painkiller_seconds = 15.0'), encoding='utf-8', newline='\n')
    (OBJ / 'item_adrenaline.tres').write_text(item_tpl % (
        'adrenaline_01', '肾上腺素',
        '原作 強化アイテム/アドレナリン。短时间内攻击力翻倍；即死类攻击不会因此变得更"即死"。',
        '15 秒内攻击力 ×2', 120, 'adrenaline_seconds = 15.0'), encoding='utf-8', newline='\n')
    made += [OBJ / 'item_painkiller.tres', OBJ / 'item_adrenaline.tres']

    # ── 角色白名单追加 ──
    for ch in ('character_nobita', 'character_bigg', 'character_shizuka', 'character_suneo'):
        p = OBJ / (ch + '.tres')
        txt = p.read_text(encoding='utf-8')
        for key, ids in (('allowed_primary_weapons', PRIMARY_NEW),
                         ('allowed_secondary_weapons', SECONDARY_NEW)):
            m = re.search(r'^%s = Array\[String\]\(\[(.*?)\]\)$' % key, txt, re.M)
            if not m:
                raise SystemExit('%s 缺少 %s' % (ch, key))
            have = re.findall(r'"([^"]+)"', m.group(1))
            merged = have + [i for i in ids if i not in have]
            line = '%s = Array[String]([%s])' % (key, ', '.join('"%s"' % i for i in merged))
            txt = txt[:m.start()] + line + txt[m.end():]
        p.write_text(txt, encoding='utf-8', newline='\n')

    print('生成 %d 个文件' % len(made))
    for p in made:
        print('  ', p.relative_to(ROOT))


if __name__ == '__main__':
    main()
