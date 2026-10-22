#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对齐原作武器变种 + 补齐投掷物/医疗品 + 按说明书配图换武器图标。

一次性脚本（2026-10-22）：
  ① 5 类枪械按原作对齐：把"通用型号"的 _01 换成原作第一把，
     删掉多出来的、把重火器（M249 / 巴雷特）挪出步枪/狙击编号；
  ② 补投掷物（ディモ酢瓶 / ボルトグレネード / 液体窒素 / スローイングナイフ）；
  ③ 补医疗品（救急箱 / グリーンハーブ調合）；
  ④ 用 `E:/15.L3D/readme/weapon_img/*.png` 与 `art/Ui/装備アイコン*.png`
     做灰度指纹匹配（24×24，平均绝对差），把每个武器/道具的 icon 换成对应图。

运行：python tools/align_weapons_to_original.py
"""
import re
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OBJ = ROOT / 'object'
ICON_DIR = ROOT / 'art' / 'Ui'
IMG_DIR = Path('E:/15.L3D/readme/weapon_img')
SIG_SIZE = 24


# ────────────────────────────── 图标匹配 ──────────────────────────────

def sig(path, size=SIG_SIZE):
    im = Image.open(path).convert('RGBA')
    bg = Image.new('RGBA', im.size, (255, 255, 255, 255))
    bg.alpha_composite(im)
    return list(bg.convert('L').resize((size, size), Image.Resampling.BILINEAR).getdata())


def build_icon_index():
    out = {}
    for p in ICON_DIR.glob('装備アイコン*.png'):
        out[p] = sig(p)
    return out


def best_icon(target_sig, index):
    best = (1e9, None)
    for p, s in index.items():
        d = sum(abs(a - b) for a, b in zip(target_sig, s)) / len(s)
        if d < best[0]:
            best = (d, p)
    return best


def icon_uid(path):
    imp = Path(str(path) + '.import')
    m = re.search(r'uid="([^"]+)"', imp.read_text(encoding='utf-8'))
    return m.group(1) if m else ''


def apply_icon(tres_path, icon_path):
    """把 .tres 的 icon 换成 icon_path（保留其它 ext_resource）。"""
    txt = Path(tres_path).read_text(encoding='utf-8')
    uid = icon_uid(icon_path)
    res = 'res://art/Ui/%s' % icon_path.name
    line_pat = re.compile(r'^\[ext_resource type="Texture2D"[^\]]*id="icon"\]$', re.M)
    new_line = '[ext_resource type="Texture2D" uid="%s" path="%s" id="icon"]' % (uid, res)
    if line_pat.search(txt):
        txt = line_pat.sub(new_line, txt, count=1)
    else:
        txt = txt.replace('\n[resource]', '\n%s\n\n[resource]' % new_line, 1)
        txt = txt.replace('item_type = ', 'item_type = ', 1)
        if not re.search(r'^icon = ', txt, re.M):
            txt = txt.replace('\n', '\nicon = ExtResource("icon")\n', 1) if False else txt
    if not re.search(r'^icon = ', txt, re.M):
        txt = txt.rstrip('\n') + '\nicon = ExtResource("icon")\n'
    Path(tres_path).write_text(txt, encoding='utf-8', newline='\n')


# ────────────────────────────── ① 武器对齐 ──────────────────────────────

def set_field(text, key, value):
    pat = re.compile(r'^%s = .*$' % re.escape(key), re.M)
    if pat.search(text):
        return pat.sub('%s = %s' % (key, value), text, count=1)
    for cand in (r'^attack_power = .*$', r'^item_type = .*$', r'^item_name = .*$'):
        anchor = re.search(cand, text, re.M)
        if anchor:
            return text[:anchor.end()] + '\n%s = %s' % (key, value) + text[anchor.end():]
    return text.rstrip('\n') + '\n%s = %s\n' % (key, value)


WEAPON_ALIGN = {
    # 文件 → (item_id, 名称, 威力, 射程, 弹匣, 备弹, 攻速, 说明, 原作配图)
    'weapon_pistol.tres': ('pistol_01', '贝雷塔 M92F', 25, 200, 12, 24, 1.0,
                              '原作 ハンドガン/ﾍﾞﾚｯﾀM92F（威力15／连射C／射程B）。标准制式手枪。', 'HGUN_M92F.png'),
    'weapon_smg.tres': ('smg_01', 'Vz61 蝎式', 23, 190, 20, 300, 1.1,
                           '原作 ｻﾌﾞﾏｼﾝｶﾞﾝ/Vz61（威力15／连射A）。轻小、弹匣少，撒得快。', 'SUB_Vz61.png'),
    'weapon_rifle.tres': ('rifle_01', 'AK-47', 23, 200, 30, 350, 1.0,
                             '原作 ｱｻﾙﾄﾗｲﾌﾙ/AK-47（威力20／连射B）。备弹多、单发偏低。', 'AR_AK.png'),
    'weapon_rifle_02.tres': ('rifle_02', 'M4-A1', 35, 200, 30, 270, 1.05,
                             '原作 ｱｻﾙﾄﾗｲﾌﾙ/M4-A1（威力30／连射B）。精度与威力均衡。', 'AR_M4.png'),
    'weapon_rifle_03.tres': ('rifle_03', 'FA-MAS', 29, 200, 25, 230, 1.15,
                             '原作 ｱｻﾙﾄﾗｲﾌﾙ/FA-MAS（威力25／连射A）。射速快、备弹少。', 'AR_FAMAS.png'),
    'weapon_shotgun.tres': ('shotgun_01', 'M870 霰弹枪', 45, 200, 5, 300, 1.0,
                               '原作 ショットガン/M870（威力40／连射D）。泵动式，单发最重。', 'SHOT_M870.png'),
    'weapon_sniper.tres': ('sniper_01', 'M700 狙击枪', 55, 300, 10, 120, 1.0,
                              '原作 ｽﾅｲﾊﾟｰﾗｲﾌﾙ/M700（威力150／连射D／射程A）。栓动狙击。', 'SNI_M700.png'),
}

# 重火器挪出步枪/狙击编号
HEAVY_RENAME = {
    'weapon_rifle_05.tres': ('weapon_mg_01.tres', 'rifle_05', 'mg_01'),
    'weapon_sniper_04.tres': ('weapon_at_rifle_01.tres', 'sniper_04', 'at_rifle_01'),
}

WEAPON_ICONS = {
    'weapon_pistol_02.tres': 'HGUN_SW.png',
    'weapon_pistol_03.tres': 'HGUN_FN57.png',
    'weapon_pistol_04.tres': 'HGUN_M93R.png',
    'weapon_smg_02.tres': 'SUB_P90.png',
    'weapon_smg_03.tres': 'SUB_MP5.png',
    'weapon_shotgun_02.tres': 'SHOT_M4.png',
    'weapon_shotgun_03.tres': 'SHOT_STR.png',
    'weapon_sniper_02.tres': 'SNI_DORA.png',
    'weapon_sniper_03.tres': 'SNI_PSG1.png',
    'weapon_magnum_01.tres': 'MGN_ANA.png',
    'weapon_magnum_02.tres': 'MGN_DE.png',
    'weapon_magnum_03.tres': 'MGN_END.png',
    'weapon_grenade_launcher.tres': 'GR_M79.png',
    'weapon_launcher_02.tres': 'GR_MGL.png',
    'weapon_rocket_launcher.tres': 'ROCKET_RPG.png',
    'weapon_rocket_02.tres': 'ROCKET_M202.png',
    'weapon_rocket_03.tres': 'ROCKET_HOMING.png',
    'weapon_bowgun.tres': 'BOW.png',
    'weapon_mg_01.tres': 'HW_MINIMI.png',
    'weapon_at_rifle_01.tres': 'material_rifle.png',
}

DROP_WEAPONS = ['weapon_smg_04.tres', 'weapon_rifle_04.tres']


# ────────────────────────────── ② / ③ 投掷物 & 医疗品 ──────────────────────────

THROWABLE_NEW = [
    # 文件名, 基础文件, item_id, 名称, 说明, 效果, 覆盖字段, 原作配图
    ('item_acid_bottle.tres', 'item_molotov.tres', 'acid_bottle_01', 'ディモ酢瓶',
     '原作 投擲物/ディモ酢瓶。碎裂后泼出强酸，持续腐蚀。', '酸液腐蚀',
     {'element': 4, 'damage': 25.0}, 'THROW_ACID.png'),
    ('item_bolt_grenade.tres', 'item_grenade.tres', 'bolt_grenade_01', 'ボルトグレネード',
     '原作 投擲物/ボルトグレネード。破片手雷，范围伤害。', '爆炸（破片）',
     {'damage': 180.0}, 'THROW_BOLT.png'),
    ('item_nitrogen.tres', 'item_grenade.tres', 'nitrogen_01', '液体窒素ボトル',
     '原作 投擲物/液体窒素ボトル。低温冻结范围内的敌人。', '冰结',
     {'element': 3, 'damage': 60.0}, 'THROW_LIQUIDN.png'),
    ('item_throwing_knife.tres', 'item_grenade.tres', 'throwing_knife_01', 'スローイングナイフ',
     '原作 投擲物/スローイングナイフ。单体高伤，无爆炸范围。', '单体投掷',
     {'explosion_radius': 0, 'damage': 90.0}, 'THROW_KNIFE.png'),
]

MEDICAL_NEW = [
    ('item_aid_box.tres', 'item_first_aid_spray.tres', 'aid_box_01', '救急箱',
     '原作战地补给。一次性大幅回复 HP。', '回复 +100 HP', {'hp_restore': 100}, 'OTHER_AIDBOX.png'),
    ('item_herb_mixed.tres', 'item_potion.tres', 'herb_mixed_01', 'グリーンハーブ調合',
     '原作 調合ハーブ。比单株草药回复更多。', '回复 +80 HP', {'hp_restore': 80}, 'OTHER_HERB.png'),
]


def copy_with_overrides(dst, base, fields):
    txt = (OBJ / base).read_text(encoding='utf-8')
    txt = re.sub(r'^\[gd_resource ([^\]]*?) uid="[^"]*"', r'[gd_resource \1', txt, count=1, flags=re.M)
    for k, v in fields.items():
        if isinstance(v, str):
            v = '"%s"' % v
        elif isinstance(v, float):
            v = '%.1f' % v
        txt = set_field(txt, k, v)
    (OBJ / dst).write_text(txt, encoding='utf-8', newline='\n')


def main():
    index = build_icon_index()

    # ① 武器对齐
    for fname, (vid, name, power, rng, mag, reserve, speed, desc, img) in WEAPON_ALIGN.items():
        p = OBJ / fname
        txt = p.read_text(encoding='utf-8')
        txt = set_field(txt, 'item_id', '"%s"' % vid)
        txt = set_field(txt, 'item_name', '"%s"' % name)
        txt = set_field(txt, 'description', '"%s"' % desc)
        txt = set_field(txt, 'attack_power', power)
        txt = set_field(txt, 'attack_range', '%.1f' % rng)
        txt = set_field(txt, 'magazine_capacity', mag)
        txt = set_field(txt, 'initial_reserve_ammo', reserve)
        txt = set_field(txt, 'attack_speed', '%.2f' % speed)
        p.write_text(txt, encoding='utf-8', newline='\n')
        if (IMG_DIR / img).exists():
            apply_icon(p, best_icon(sig(IMG_DIR / img), index)[1])

    # 重火器改 id / 改名（文件也改名）
    for old, (new_name, old_id, new_id) in HEAVY_RENAME.items():
        src = OBJ / old
        dst = OBJ / new_name
        if not src.exists():
            continue   # 已改名（脚本可重跑）
        txt = src.read_text(encoding='utf-8')
        txt = set_field(txt, 'item_id', '"%s"' % new_id)
        dst.write_text(txt, encoding='utf-8', newline='\n')
        src.unlink()

    # 删除多出来的变种
    for f in DROP_WEAPONS:
        p = OBJ / f
        if p.exists():
            p.unlink()

    # ② 投掷物
    for dst, base, vid, name, desc, effect, overrides, img in THROWABLE_NEW:
        fields = {'item_id': vid, 'item_name': name, 'description': desc, 'effect_text': effect}
        fields.update(overrides)
        copy_with_overrides(dst, base, fields)
        if (IMG_DIR / img).exists():
            apply_icon(OBJ / dst, best_icon(sig(IMG_DIR / img), index)[1])

    # ③ 医疗品
    for dst, base, vid, name, desc, effect, overrides, img in MEDICAL_NEW:
        fields = {'item_id': vid, 'item_name': name, 'description': desc, 'effect_text': effect}
        fields.update(overrides)
        copy_with_overrides(dst, base, fields)
        if (IMG_DIR / img).exists():
            apply_icon(OBJ / dst, best_icon(sig(IMG_DIR / img), index)[1])

    # ④ 其余武器/道具按说明书配图换图标
    for fname, img in WEAPON_ICONS.items():
        p = OBJ / fname
        if not p.exists():
            continue
        target = IMG_DIR / img
        if target.exists():
            d, icon = best_icon(sig(target), index)
            if d < 3.0:
                apply_icon(p, icon)
                print('  %-32s ← %s (d=%.2f)' % (fname, icon.name, d))
            else:
                print('  %-32s ← 无匹配（最近 %s d=%.2f）' % (fname, icon.name, d))

    # 道具图标（強化アイテム / 既有医疗品）
    ITEM_ICONS = {
        'item_painkiller.tres': 'MED_PILL.png',
        'item_adrenaline.tres': 'MED_ADRENALINE.png',
        'item_first_aid_spray.tres': 'OTHER_SPRAY.png',
        'item_potion.tres': 'OTHER_HERB.png',
        'item_tp_potion.tres': 'OTHER_WATER.png',
        'item_grenade.tres': 'THROW_GRANADO.png',
        'item_molotov.tres': 'THROW_MORO.png',
        'throwable_dynamite.tres': 'THROW_DYNA.png',
        'throwable_flash.tres': 'THROW_FLASH.png',
    }
    for fname, img in ITEM_ICONS.items():
        p = OBJ / fname
        target = IMG_DIR / img
        if not p.exists() or not target.exists():
            continue
        d, icon = best_icon(sig(target), index)
        if d < 3.0:
            apply_icon(p, icon)
            print('  %-32s ← %s (d=%.2f)' % (fname, icon.name, d))

    print('done')


if __name__ == '__main__':
    main()
