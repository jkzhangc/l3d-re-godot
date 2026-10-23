#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_melee_weapons.py — 按原作数据库补齐「突袭」战役掉落表里的近战武器

数据来源：`E:/15.L3D/RPG_RT.ldb`（原作 RM2K3 工程，Shift-JIS）的 **武器区 0x0D**，
用 `tools/rm2k3_map_restore/dump_orig_db.py` 解出日文名与说明；
掉落关系见 `原作突袭战役掉落物逻辑.md` §2.1「僵尸掉落」表。

已存在（跳过）：金属バット(308)=weapon_metal_bat / フライパン(448)=weapon_frypan /
              コンバットナイフ 属下的 小刀=weapon_knife
本次补齐 7 把：防火斧 310 / スレッジハンマー 311 / シャベル 316 / 鉄パイプ 317 /
              コンバットナイフ 444 / 打刀 449 / メリケンサック 454

数值标尺以项目现有三把为准：小刀 15 / 平底锅 25 / 金属球棒 40。
原作武器记录里没有可直接换算的攻击力（字段全是 0/30/36 的暴击与命中），
所以攻击力按「同类武器在项目里的相对强弱」定，不冒充原作数值。

用法：python tools/gen_melee_weapons.py [--dry]
"""
import sys
from pathlib import Path

ROOT = Path(r"D:\!bird's-eye-view-arpg-test-\l3d-re-godot")
OBJ = ROOT / "object"

SCRIPT = "res://script/weapon_data.gd"
WALK = "res://art/Characters/のび太セット近战1.png"
HIT_FX = "res://anim/anim_effect_hit.tscn"
SND_SWING = "res://sound/bio1_ナイフ空振り.ogg"
SND_HIT = "res://sound/打撃5.ogg"
SND_RAISE = "res://sound/カチャ.ogg"

## kind: "blade" = 剑类（4 帧攻击 / 有两连击），"two_hand" = 双手持（2 帧）
WEAPONS = [
    dict(file="weapon_fire_axe", id="fire_axe", name="防火斧", orig="防火斧", orig_id=310,
         state="FireAxe", walk="res://art/Characters/のび太セット近战3.png",
         power=55, speed=0.65, crit=20.0, kind="two_hand", fam="防火斧",
         icon="装備アイコン処刑者の大斧.png", price=200,
         box=(78, 44), fwd=32,
         desc="消防栓旁的破拆斧。双手抡，砍中防具也照穿；起手慢，落空就是大破绽。"),
    dict(file="weapon_sledgehammer", id="sledgehammer", name="大锤", orig="スレッジハンマー", state="Sledgehammer",
         orig_id=311, power=65, speed=0.55, crit=25.0, kind="two_hand", fam="スレッジハンマー",
         icon="装備アイコン処刑者の大斧.png", price=300,
         box=(86, 48), fwd=34,
         desc="工事用的大锤。伤害是近战里最高的一档，但抡起来几乎挪不动脚。"),
    dict(file="weapon_shovel", id="shovel", name="铁锹", orig="シャベル", orig_id=316, state="Shovel",
         power=45, speed=0.75, crit=15.0, kind="two_hand", fam="シャベル",
         icon="装備アイコンシャベル.png", price=150,
         box=(74, 40), fwd=30,
         desc="挖工事用的铁锹。刃口磨过，劈砍比想象中利；重量比大锤轻一档。"),
    dict(file="weapon_pipe", id="pipe", name="铁管", orig="鉄パイプ", orig_id=317, state="Pipe",
         power=35, speed=0.85, crit=15.0, kind="blade", fam="鉄パイプ",
         icon="装備アイコン鉄パイプ.png", price=100,
         box=(64, 36), fwd=28,
         desc="随手捡的铁管。攻击距离比小刀长，挥起来也还算快。"),
    dict(file="weapon_combat_knife", id="combat_knife", name="战斗刀", orig="コンバットナイフ", state="CombatKnife",
         orig_id=444, power=20, speed=1.25, crit=25.0, kind="blade", fam="人斬り包丁",
         icon="装備アイコンナイフ.png", price=120,
         box=(48, 34), fwd=22,
         desc="军用战斗刀。比小刀沉一点、伤害高一档，出手依旧很快。"),
    dict(file="weapon_uchigatana", id="uchigatana", name="打刀", orig="打刀", orig_id=449, state="Uchigatana",
         power=50, speed=1.0, crit=30.0, kind="blade", fam="打刀",
         icon="装備アイコン打刀.png", price=280,
         box=(76, 36), fwd=32,
         desc="刃口完好的日本刀。挥速快、会心高，两连击能一口气切开两只丧尸。"),
    dict(file="weapon_knuckles", id="knuckles", name="指虎", orig="メリケンサック", orig_id=454, state="Knuckles",
         power=18, speed=1.3, crit=25.0, kind="blade", fam="爪",
         icon="装備アイコンメリケンサック.png", price=80,
         box=(40, 32), fwd=18,
         desc="套在指节上的铁块。伤害最低但出手最快，适合贴身补刀。"),
]

## 攻击序列：剑类 4 帧（含两连击），双手持 2 帧
SEQ = {
    "blade": ([3, 4, 5, 2], [0.10, 0.10, 0.20, 0.10], "{0: 0, 1: 1, 2: 1, 3: 2}"),
    "two_hand": ([3, 4], [0.16, 0.20], "{0: 0, 1: 1}"),
}


def arr_ints(v):
    return "Array[int]([%s])" % ", ".join(str(x) for x in v)


def arr_floats(v):
    return "Array[float]([%s])" % ", ".join(("%g" % x) for x in v)


def build(w):
    seq, durs, cols = SEQ[w["kind"]]
    sheet = "res://art/WeaponAttack/%s/%s_attack1.png" % (w["fam"], w["fam"])
    walk = w.get("walk", WALK)
    icon = "res://art/Ui/" + w["icon"]
    return """[gd_resource type="Resource" script_class="WeaponData" format=3]

[ext_resource type="Script" path="%(script)s" id="1"]
[ext_resource type="Texture2D" path="%(walk)s" id="2"]
[ext_resource type="Texture2D" path="%(sheet)s" id="3"]
[ext_resource type="Texture2D" path="%(icon)s" id="4"]
[ext_resource type="AudioStream" path="%(swing)s" id="5"]
[ext_resource type="AudioStream" path="%(hit)s" id="6"]
[ext_resource type="AudioStream" path="%(raise_snd)s" id="7"]
[ext_resource type="PackedScene" path="%(fx)s" id="8"]

[resource]
script = ExtResource("1")
attack_power = %(power)d
attack_speed = %(speed)g
weapon_state_name = "%(state)s"
weapon_walk_texture = ExtResource("2")
is_ranged = false
weapon_slot = 1
critical_rate = %(crit)g
attack_sound = ExtResource("5")
empty_fire_sound = ExtResource("7")
raise_sound = ExtResource("7")
lower_sound = ExtResource("7")
hit_sound = ExtResource("6")
hit_effect_anim = ExtResource("8")
attack_char_sequence = %(seq)s
melee_attack_char_sequence = %(seq)s
melee_attack_frame_durations = %(durs)s
melee_range_size = Vector2(%(bw)d, %(bh)d)
melee_range_forward_offset = %(fwd)g
melee_weapon_sprite = ExtResource("3")
melee_weapon_sprite_seq_cols = %(cols)s
item_id = "%(id)s"
item_name = "%(name)s"
item_type = 3
description = "%(desc)s"
icon = ExtResource("4")
sell_price = %(price)d
max_stack = 1
""" % dict(script=SCRIPT, walk=walk, sheet=sheet, icon=icon, swing=SND_SWING, hit=SND_HIT,
           raise_snd=SND_RAISE, fx=HIT_FX, power=w["power"], speed=w["speed"], crit=w["crit"],
           seq=arr_ints(seq), durs=arr_floats(durs), bw=w["box"][0], bh=w["box"][1],
           fwd=w["fwd"], cols=cols, id=w["id"], name=w["name"], desc=w["desc"],
           state=w["state"],
           price=w["price"])


def main() -> None:
    dry = "--dry" in sys.argv
    for w in WEAPONS:
        text = build(w)
        path = OBJ / (w["file"] + ".tres")
        print("%-28s %-6s 攻击%2d 速度%.2f  %s ← 原作#%d %s" % (
            w["file"], w["name"], w["power"], w["speed"], w["kind"], w["orig_id"], w["orig"]))
        if dry:
            continue
        path.write_text(text, encoding="utf-8", newline="\n")
    print("\n共 %d 件%s" % (len(WEAPONS), "（dry run，未写盘）" if dry else " 已写入 object/"))


if __name__ == "__main__":
    main()
