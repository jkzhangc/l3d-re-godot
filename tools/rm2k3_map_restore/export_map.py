#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RM2K3 LMU -> baked 32px atlas + auditable TileMap JSON exporter."""
import argparse, json, struct, zlib
from pathlib import Path
from PIL import Image

D_GROUP_ORIGIN=((0,8),(3,8),(0,12),(3,12),(6,0),(9,0),(6,4),(9,4),(6,8),(9,8),(6,12),(9,12))
# RPG Maker 2000/2003 地图最小尺寸，用于在 LMU 缺宽高字段时反推唯一尺寸
MIN_MAP_WIDTH,MIN_MAP_HEIGHT=20,15
# ── 下层 ID 分区（EasyRPG map_data.h，权威）─────────────────────────────
#   BLOCK_A 0     ..  1999   水面自动图块（2 个 A 组，见下）
#   BLOCK_B 2000  ..  2999   深水（同属水面自动图块，用 A 组做岸线 + B 组做水身）
#   BLOCK_C 3000  ..  3149   另外 3 个 4 帧动画（列 3..5，行 4..7）—— 漩涡等
#   BLOCK_D 4000  ..  4599   12 个自动图块（屋顶/墙壁/草地…）
#   BLOCK_E 5000  ..  5143   普通下层
#   BLOCK_F 10000 .. 10143   普通上层（10000 = 透明）
BLOCK_B_BASE = 2000
BLOCK_C_BASE, BLOCK_C_END, BLOCK_C_TILES = 3000, 3150, 3
BLOCK_A_FRAMES, BLOCK_C_FRAMES, BLOCK_ANIM_DURATION = 3, 4, 0.3

# ── 水面自动图块的四象限规则（2026-10-22 查实）──────────────────────────
# RM2K3 把「岸线形状」和「深水边界」直接编码进地图里的下层 ID：
#     ID(<3000) = block*1000 + b_subtile*50 + a_subtile
#       block 0/1 = 浅水（0..1999，A 组两套），block 2 = 深水（2000..2999）
#       a_subtile 0..46 → BlockA_Subtiles_IDS：**每个 8×8 象限取自芯片组哪一行**
#                          （-1 = 该象限改从 B 组取水身）
#       b_subtile 0..15 → 深水边界位（bit 顺序 TL,TR,BL,BR），该象限取 B 组第 4+t 行
#   来源：EasyRPG Player `src/tilemap_layer.cpp`
#         `BlockA_Subtiles_IDS` / `GenerateAutotileAB` / `RecalculateAutotile`。
#   ⚠ 与 Block D（屋顶边缘）**规则不同**：D 用 50 项、每项给出 4 个显式 (x,y) 偏移；
#     水面只有 47 项、每项只给「行号」，列由动画帧 animID（+3 用于 block 1）决定，
#     另有一趟「b/a 同时非零时用 B 组覆盖」的修正。别把两张表混用。
#   ⚠ 只做「按 ID 解码」：LMU 里存的就是已解算的变体 ID，不需要再按邻居重算。
BLOCK_A_SUBTILES_IDS = (
 ((None,None),(None,None)),                       # 0  四面都是水（全取 B 组水身）
 ((3,None),(None,None)),                          # 1
 ((None,3),(None,None)),                          # 2
 ((3,3),(None,None)),                             # 3
 ((None,None),(None,3)),                          # 4  ← 单格水池边的典型值
 ((3,None),(None,3)),                             # 5
 ((None,3),(None,3)),                             # 6
 ((3,3),(None,3)),                                # 7
 ((None,None),(3,None)),                          # 8
 ((3,None),(3,None)),                             # 9
 ((None,3),(3,None)),                             # 10
 ((3,3),(3,None)),                                # 11
 ((None,None),(3,3)),                             # 12
 ((3,None),(3,3)),                                # 13
 ((None,3),(3,3)),                                # 14
 ((3,3),(3,3)),                                   # 15
 ((1,None),(1,None)),                             # 16
 ((1,3),(1,None)),                                # 17
 ((1,None),(1,3)),                                # 18
 ((1,3),(1,3)),                                   # 19
 ((2,2),(None,None)),                             # 20
 ((2,2),(None,3)),                                # 21
 ((2,2),(3,None)),                                # 22
 ((2,2),(3,3)),                                   # 23
 ((None,1),(None,1)),                             # 24
 ((None,1),(3,1)),                                # 25
 ((3,1),(None,1)),                                # 26
 ((3,1),(3,1)),                                   # 27
 ((None,None),(2,2)),                             # 28
 ((3,None),(2,2)),                                # 29
 ((None,3),(2,2)),                                # 30
 ((3,3),(2,2)),                                   # 31
 ((1,1),(1,1)),                                   # 32
 ((2,2),(2,2)),                                   # 33
 ((0,2),(1,None)),                                # 34
 ((0,2),(1,3)),                                   # 35
 ((2,0),(None,1)),                                # 36
 ((2,0),(3,1)),                                   # 37
 ((None,1),(2,0)),                                # 38
 ((3,1),(2,0)),                                   # 39
 ((1,None),(0,2)),                                # 40
 ((1,3),(0,2)),                                   # 41
 ((0,0),(1,1)),                                   # 42
 ((0,2),(0,2)),                                   # 43
 ((1,1),(0,0)),                                   # 44
 ((2,0),(2,0)),                                   # 45
 ((0,0),(0,0)),                                   # 46 孤立单格水（四象限全取 A 组第 0 行）
)

D_QUARTER_OFFSETS=(
(((1,2),(1,2)),((1,2),(1,2))),(((2,0),(1,2)),((1,2),(1,2))),(((1,2),(2,0)),((1,2),(1,2))),(((2,0),(2,0)),((1,2),(1,2))),
(((1,2),(1,2)),((1,2),(2,0))),(((2,0),(1,2)),((1,2),(2,0))),(((1,2),(2,0)),((1,2),(2,0))),(((2,0),(2,0)),((1,2),(2,0))),
(((1,2),(1,2)),((2,0),(1,2))),(((2,0),(1,2)),((2,0),(1,2))),(((1,2),(2,0)),((2,0),(1,2))),(((2,0),(2,0)),((2,0),(1,2))),
(((1,2),(1,2)),((2,0),(2,0))),(((2,0),(1,2)),((2,0),(2,0))),(((1,2),(2,0)),((2,0),(2,0))),(((2,0),(2,0)),((2,0),(2,0))),
(((0,2),(0,2)),((0,2),(0,2))),(((0,2),(2,0)),((0,2),(0,2))),(((0,2),(0,2)),((0,2),(2,0))),(((0,2),(2,0)),((0,2),(2,0))),
(((1,1),(1,1)),((1,1),(1,1))),(((1,1),(1,1)),((1,1),(2,0))),(((1,1),(1,1)),((2,0),(1,1))),(((1,1),(1,1)),((2,0),(2,0))),
(((2,2),(2,2)),((2,2),(2,2))),(((2,2),(2,2)),((2,0),(2,2))),(((2,0),(2,2)),((2,2),(2,2))),(((2,0),(2,2)),((2,0),(2,2))),
(((1,3),(1,3)),((1,3),(1,3))),(((2,0),(1,3)),((1,3),(1,3))),(((1,3),(2,0)),((1,3),(1,3))),(((2,0),(2,0)),((1,3),(1,3))),
(((0,2),(2,2)),((0,2),(2,2))),(((1,1),(1,1)),((1,3),(1,3))),(((0,1),(0,1)),((0,1),(0,1))),(((0,1),(0,1)),((0,1),(2,0))),
(((2,1),(2,1)),((2,1),(2,1))),(((2,1),(2,1)),((2,0),(2,1))),(((2,3),(2,3)),((2,3),(2,3))),(((2,0),(2,3)),((2,3),(2,3))),
(((0,3),(0,3)),((0,3),(0,3))),(((0,3),(2,0)),((0,3),(0,3))),(((0,1),(2,1)),((0,1),(2,1))),(((0,1),(0,1)),((0,3),(0,3))),
(((0,3),(2,3)),((0,3),(2,3))),(((2,1),(2,1)),((2,3),(2,3))),(((0,1),(2,1)),((0,3),(2,3))),(((1,2),(1,2)),((1,2),(1,2))),
(((1,2),(1,2)),((1,2),(1,2))),(((0,0),(0,0)),((0,0),(0,0))))

def ber(data,pos=0):
    v=0
    while True:
        b=data[pos]; pos+=1; v=(v<<7)|(b&127)
        if not b&128: return v,pos

def chunks(data,pos):
    while pos+1<len(data):
        cid,p=ber(data,pos); ln,q=ber(data,p)
        if q+ln>len(data): break
        yield cid,data[q:q+ln]; pos=q+ln

def read_lmu(path):
    data=path.read_bytes(); out={'chipset':None,'width':None,'height':None,'lower':[],'upper':[]}
    for cid,payload in chunks(data,data.index(b'LcfMapUnit')+10):
        if cid==1 and len(payload)==1: out['chipset']=payload[0]
        elif cid==2: out['width'],_=ber(payload)
        elif cid==3: out['height'],_=ber(payload)
        elif cid in (0x47,0x48): out['lower' if cid==0x47 else 'upper']=list(struct.unpack('<%dH'%(len(payload)//2),payload))
    if out['width'] is not None and out['height'] is not None:
        expected=out['width']*out['height']
        if len(out['lower'])!=expected or len(out['upper'])!=expected:
            raise ValueError('LMU layer size mismatch')
    return out

def decode_xyz(path):
    """Load RM2K3 chipset and apply only its exact transparency key."""
    raw = path.read_bytes()
    if raw[:4] == b'XYZ1':
        payload = zlib.decompress(raw[8:])
        pixels = payload[768:]
        im = Image.frombytes('P', (480, 256), pixels)
        im.putpalette(payload[:768])
        im = im.convert('RGBA')
        im.putalpha(Image.frombytes('L', im.size, bytes(0 if i == 0 else 255 for i in pixels)))
        return im
    indexed = Image.open(path)
    if indexed.size != (480, 256):
        raise ValueError('chipset must be 480x256, got ' + repr(indexed.size))
    if indexed.mode == 'P':
        pixels = indexed.copy()
        existing = pixels.info.get('transparency')
        rgba = pixels.convert('RGBA')
        if existing is None:
            # P 模式 tobytes() 即逐像素调色板索引（行主序），等价于 getdata() 但无弃用告警
            indices = pixels.tobytes()
            rgba.putalpha(Image.frombytes('L', pixels.size, bytes(0 if i == 0 else 255 for i in indices)))
        return rgba
    return indexed.convert('RGBA')


def render_d(source,tile_id):
    group,variant=divmod(tile_id-4000,50); ox,oy=D_GROUP_ORIGIN[group]; offsets=D_QUARTER_OFFSETS[variant]; out=Image.new('RGBA',(16,16))
    for row in range(2):
        for col in range(2):
            qx,qy=offsets[row][col]; x=((ox+qx)*2+col)*8; y=((oy+qy)*2+row)*8
            out.alpha_composite(source.crop((x,y,x+8,y+8)),(col*8,row*8))
    return out

def render_regular(source,value):
    if 5000<=value<5144:
        n=value-5000; tx=12+n%6 if n<96 else 18+(n-96)%6; ty=n//6 if n<96 else (n-96)//6
    elif 10001<=value<10144:
        n=value-10000; tx=18+n%6 if n<48 else 24+(n-48)%6; ty=8+n//6 if n<48 else (n-48)//6
    else: return None
    return source.crop((tx*16,ty*16,tx*16+16,ty*16+16))

def water_quarters(block,b_subtile,a_subtile):
    """水面自动图块 → 4 个 8×8 象限的 (芯片组列偏移, 行号)。

    与 EasyRPG `GenerateAutotileAB` 同序（三趟覆盖），列偏移是**相对动画帧列**的：
    实际列 = animID + offset。返回 [[(dx,row)]*2]*2，索引 [row][col]。
    """
    q=[[None,None],[None,None]]
    table=BLOCK_A_SUBTILES_IDS[a_subtile]
    # ① 表里为 None 的象限：取 B 组水身（行 4+t，t 来自 b_subtile 的 TL,TR,BL,BR 位）
    for j in range(2):
        for i in range(2):
            if table[j][i] is not None:
                continue
            t=(b_subtile>>(j*2+i))&1
            if block==2: t^=3
            q[j][i]=(0,4+t)
    # ② 表里给了行号的象限：取 A 组该行（block 1 用右侧那一组列）
    for j in range(2):
        for i in range(2):
            if table[j][i] is None:
                continue
            q[j][i]=(3 if block==1 else 0,table[j][i])
    # ③ b、a 同时非零：深水边界再覆盖一次（与上游实现一致，别删）
    if b_subtile!=0 and a_subtile!=0:
        for j in range(2):
            for i in range(2):
                t=(b_subtile>>(j*2+i))&1
                if block==2: t*=2
                if t==0: continue
                q[j][i]=(0,4+t)
    return q

def render_water(source,value,frame=0):
    """水面（ID < 3000）：按 4 个 8×8 象限拼一张完整 16×16。

    frame = 动画帧（0..2）= 芯片组 A 组内的列偏移。
    非法变体（a>46 / b>15）按「全水」处理而不是丢弃 —— 宁可画成水，也不要在
    地图上留一个洞（2026-10-22：旧实现静默丢弃导致水池边整圈变空洞）。
    """
    block=value//1000
    rest=value-block*1000
    b_subtile,a_subtile=divmod(rest,50)
    if a_subtile>=len(BLOCK_A_SUBTILES_IDS) or b_subtile>=16:
        b_subtile,a_subtile=0,0
    plan=water_quarters(block,b_subtile,a_subtile)
    out=Image.new('RGBA',(16,16))
    for j in range(2):
        for i in range(2):
            dx,row=plan[j][i]
            sx=(frame+dx)*16+i*8
            sy=row*16+j*8
            out.alpha_composite(source.crop((sx,sy,sx+8,sy+8)),(i*8,j*8))
    return out

def render_block_c(source,value,frame=0):
    """Block C（3000..3149）：3 个 4 帧动画，列 3..5、行 4..7（漩涡等）。

    frame = 0..3（RM2K3 每 6 个游戏帧换一帧）。静态转换取 frame 0。
    """
    n=(value-BLOCK_C_BASE)//50
    if n<0 or n>=BLOCK_C_TILES:
        return None
    col=3+n
    row=4+(frame%BLOCK_C_FRAMES)
    return source.crop((col*16,row*16,col*16+16,row*16+16))

def render_tile(source,value,frame=0):
    if 4000<=value<4600: return render_d(source,value)
    if 0<=value<BLOCK_C_BASE: return render_water(source,value,frame)
    if BLOCK_C_BASE<=value<BLOCK_C_END: return render_block_c(source,value,frame)
    return render_regular(source,value)


def infer_dimensions(cell_count):
    """LMU 缺宽高字段时，用格数 + RM2K3 地图最小尺寸反推唯一尺寸。

    RPG Maker 2000/2003 地图最小为 20×15，因此只在满足 w>=20 且 h>=15 的因式
    分解里找；**恰好只有一组**才返回，多解一律返回 None（交回调用方要显式宽高，
    不做猜测）。例：300 格 → 唯一 (20,15)（25×12 / 30×10 / 50×6 等因 h<15 被排除）。
    """
    candidates = [(w, cell_count // w) for w in range(MIN_MAP_WIDTH, cell_count + 1)
                  if cell_count % w == 0 and cell_count // w >= MIN_MAP_HEIGHT]
    return candidates[0] if len(candidates) == 1 else None

# id → 芯片组文件名 的 LDB 查询缓存（LDB 有几 MB，按 game_dir 缓存一次即可）
_LDB_CHIPSET_CACHE={}

def chipset_stem_from_ldb(game_dir,chipset_id):
    """从 RPG_RT.ldb 的芯片组表(区 0x14)取该 id 的芯片组文件名（无扩展名）。

    2026-09-16 修：原先 find_chipset 只认一张硬编码表（id 6/7/15/16/39），
    Map0136 用的 id 24 直接抛 FileNotFoundError（转换第一步就挂）。
    LDB 是唯一权威来源（rm2k3_autotile_atlas 也是从 LMU 读出 id 再交给本函数的），
    所以改为查 LDB；硬编码表降级为兜底（LDB 缺失/解析失败时仍可跑旧地图）。
    解析失败不抛异常，返回 None 让调用方走兜底，避免把工具整体打断。
    """
    key=str(game_dir)
    if key not in _LDB_CHIPSET_CACHE:
        table={}
        try:
            from parse_lcf import parse_ldb_chipsets
            table,_sec=parse_ldb_chipsets(game_dir/'RPG_RT.ldb',game_dir/'ChipSet')
        except Exception as exc:
            print('[warn] 读取 LDB 芯片组表失败（回退到内置表）: %s' % exc)
        _LDB_CHIPSET_CACHE[key]=table
    entry=_LDB_CHIPSET_CACHE[key].get(int(chipset_id))
    if not entry:
        return None
    return entry.get('file') or None

def find_chipset(game_dir,chipset_id,override):
    if override:
        p=Path(override); p=p if p.is_absolute() else game_dir/'ChipSet'/p
        if p.exists(): return p
    # ── 同名多扩展的源选择（2026-09-12 修）──
    # LDB 只存无扩展名，RPG_RT / EasyRPG（filefinder IMG_TYPES）按 .bmp > .png > .xyz
    # 的顺序取文件。同名 .png 与 .xyz 内容可能不同步：实测 芯片组15 洞窟L3D 两个版本
    # 差 482px（.xyz 缺一整段岩石带、多一行不透明黑线）——游戏实际渲染的是 .png，
    # 取 .xyz 作源会让转换产物出现原游戏没有的 1px 黑线（用户报告的"上层图块串色"）。
    ext_priority={'.bmp':0,'.png':1,'.xyz':2}
    d=game_dir/'ChipSet'
    def best(stem):
        if not d.is_dir():
            return None
        hits=[p for p in d.iterdir() if p.is_file() and p.stem==stem and p.suffix.lower() in ext_priority]
        if not hits:   # 大小写不一致的文件系统（或 LDB 名与磁盘名仅大小写不同）再试一次
            hits=[p for p in d.iterdir() if p.is_file() and p.stem.lower()==stem.lower()
                  and p.suffix.lower() in ext_priority]
        return min(hits,key=lambda p:ext_priority[p.suffix.lower()]) if hits else None
    # ── ① 权威来源：LDB 芯片组表（id → 文件名）──
    ldb_stem=chipset_stem_from_ldb(game_dir,chipset_id)
    if ldb_stem:
        p=best(ldb_stem)
        if p: return p
    # ── ② 兜底：内置表（历史 5 个 id；LDB 缺失或名字对不上时仍可转换）──
    preferred={'6':'妛峑丒奜娤_仜','7':'妛峑 撪娤 - 仜','15':'摯孉L3D','16':'01 - 仜','39':'01 - 仜'}
    stem=preferred.get(str(chipset_id))
    if stem:
        p=best(stem)
        if p: return p
    hint=('LDB 表里 id %s = %r，但 ChipSet 目录下找不到该文件' % (chipset_id,ldb_stem)) if ldb_stem \
        else ('LDB 表里没有 id %s' % chipset_id)
    raise FileNotFoundError('chipset not found for id %s（%s）; use --chipset 指定芯片组文件'
                            % (chipset_id,hint))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('game_dir')
    ap.add_argument('map_id', type=int)
    ap.add_argument('--output', required=True)
    ap.add_argument('--chipset')
    ap.add_argument('--width', type=int)
    ap.add_argument('--height', type=int)
    args = ap.parse_args()
    game = Path(args.game_dir)
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    m = read_lmu(game / ('Map%04d.lmu' % args.map_id))
    if m['width'] is None or m['height'] is None:
        if args.width is None or args.height is None:
            inferred = infer_dimensions(len(m['lower']))
            if inferred is None:
                raise ValueError('LMU lacks dimensions and cell count %d has no unique '
                                 'factorisation; pass --width and --height' % len(m['lower']))
            m['width'], m['height'] = inferred
            print('inferred dimensions from %d cells: %d x %d' % (len(m['lower']), m['width'], m['height']))
        else:
            if args.width * args.height != len(m['lower']):
                raise ValueError('override dimensions do not match %d cells' % len(m['lower']))
            m['width'], m['height'] = args.width, args.height
    elif (args.width is not None and args.height is not None and
          (args.width, args.height) != (m['width'], m['height'])):
        raise ValueError('dimension override disagrees with LMU fields')
    chip = find_chipset(game, m['chipset'], args.chipset)
    source = decode_xyz(chip)
    w, h = m['width'], m['height']
    lower_unique, upper_unique = {}, {}
    cells, render = [], Image.new('RGBA', (w * 32, h * 32))
    pending_anim, anim_lower = {}, {}

    def key_for(value):
        if value == 10000:
            return None
        ## 水面自动图块（Block A/B：0..2999）。旧实现只认 1000/2000/2004 三个 ID，
        ## 其余一律丢弃 → 水池边/河岸整圈变空洞（2026-10-22 用户实测）。
        if 0 <= value < BLOCK_C_BASE:
            key = 'A:%d' % value
            anim_lower[key] = BLOCK_A_FRAMES
            return key
        ## Block C（3000..3149）：漩涡等 3 个 4 帧动画，旧实现没有分支。
        if BLOCK_C_BASE <= value < BLOCK_C_END:
            key = 'C:%d' % value
            anim_lower[key] = BLOCK_C_FRAMES
            return key
        if 4000 <= value < 4600:
            key, target = 'D:' + str(value), lower_unique
        elif 5000 <= value < 5144:
            key, target = 'E:' + str(value - 5000), lower_unique
        elif 10001 <= value < 10144:
            key, target = 'F:' + str(value - 10000), upper_unique
        else:
            return None
        if key not in target:
            tile = render_tile(source, value)
            if tile is not None:
                target[key] = tile.resize((32, 32), Image.Resampling.NEAREST)
        return key

    for i, (lo, up) in enumerate(zip(m['lower'], m['upper'])):
        x, y = i % w, i // w
        lk, uk = key_for(lo), key_for(up)
        for value in (lo, up):
            tile = render_tile(source, value)
            if tile:
                render.alpha_composite(tile.resize((32, 32), Image.Resampling.NEAREST), (x * 32, y * 32))
        cells.append({'x': x, 'y': y, 'lower_id': lo, 'lower_key': lk,
                      'upper_id': up, 'upper_key': uk})

    # 动画帧放在最后追加：既有图块的格位坐标保持不变，复用 TileSet 时才稳定。
    # 本体键 + #序号 帧键由 write_atlas 统一摆位（帧必须在本体**右邻**）。
    for key in anim_lower:
        value = int(key.split(':')[1])
        frames = anim_lower[key]
        for f in range(frames):
            frame = render_tile(source, value, f)
            if frame is None:
                continue
            frame_key = key if f == 0 else '%s#%d' % (key, f)
            lower_unique[frame_key] = frame.resize((32, 32), Image.Resampling.NEAREST)

    def write_atlas(unique, suffix):
        """把 unique 拼成 atlas。

        ★动画本体的帧格必须**紧贴右侧**（Godot `set_tile_animation_frames_count`
        只认 cell + (i, 0)，否则采样到别的图块 → 水面闪烁串图）。因此这里先为本体
        预留 frames 个连续格，其余图块填剩下的空位。
        """
        cols = 16
        placed = {}
        occupied = set()

        def reserve(frames):
            x, y = 0, 0
            while True:
                if x + frames <= cols and all((x + i, y) not in occupied for i in range(frames)):
                    break
                x += 1
                if x + frames > cols:
                    x, y = 0, y + 1
            for i in range(frames):
                occupied.add((x + i, y))
            return x, y

        for key in unique:
            if '#' in key:
                continue
            placed[key] = reserve(int(anim_lower.get(key, 1)))
        for key in unique:
            if '#' not in key:
                continue
            base, idx = key.split('#', 1)
            bx = placed.get(base)
            if bx is not None:
                placed[key] = (bx[0] + int(idx), bx[1])
        rows = max(1, max((y for _, y in occupied), default=0) + 1)
        atlas = Image.new('RGBA', (cols * 32, rows * 32))
        tiles = {}
        for key, tile in unique.items():
            coord = placed.get(key)
            if coord is None:
                continue
            atlas.alpha_composite(tile, (coord[0] * 32, coord[1] * 32))
            tiles[key] = [coord[0], coord[1]]
        path = out / ('Map%04d_%s_tiles.png' % (args.map_id, suffix))
        atlas.save(path)
        return path, cols, rows, tiles

    lower_path, lower_cols, lower_rows, lower_tiles = write_atlas(lower_unique, 'lower')
    upper_path, upper_cols, upper_rows, upper_tiles = write_atlas(upper_unique, 'upper')
    prefix = 'Map%04d' % args.map_id
    render_path = out / (prefix + '_render.png')
    json_path = out / (prefix + '_tilemap.json')
    render.save(render_path)
    data = {'map_id': args.map_id, 'width': w, 'height': h,
            'chipset': m['chipset'], 'chipset_file': str(chip), 'tile_size': 32,
            'lower_atlas': lower_path.name, 'lower_atlas_columns': lower_cols,
            'lower_atlas_rows': lower_rows, 'lower_tiles': lower_tiles,
            'upper_atlas': upper_path.name, 'upper_atlas_columns': upper_cols,
            'upper_atlas_rows': upper_rows, 'upper_tiles': upper_tiles,
            'render': render_path.name, 'cells': cells,
            'mapping': {'0..2999': 'water autotile (Block A/B): '
                                   'block*1000 + b_subtile*50 + a_subtile, '
                                   '4 quadrants from A rows 0..3 / B rows 4..7',
                        '3000..3149': 'Block C animated decoration (whirlpool etc.), '
                                      '4 frames at chipset cols 3..5 rows 4..7',
                        '4000+50*g+v': 'D baked quadrants',
                        '5000+n': 'E ordinary lower',
                        '10000+n': 'F ordinary upper; 10000 transparent',
                        'A:<id>': 'Block A/B water; frames share the row, '
                                  'frame files carry the #<index> suffix',
                        'C:<id>': 'Block C 4-frame animation; same #<index> suffix'},
            'animation': {'lower': anim_lower, 'duration': BLOCK_ANIM_DURATION,
                          'note': 'frame 0 的格位即 lower_tiles 里的坐标，'
                                  '右侧连续格为其余帧（水面 3 帧 / Block C 4 帧）'}}
    json_path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf8')
    print('saved', json_path); print('saved', lower_path); print('saved', upper_path)
    print('saved', render_path); print('lower tiles', len(lower_tiles), 'upper tiles', len(upper_tiles), 'map', w, 'x', h)
    if anim_lower:
        print('animated lower tiles:', ', '.join(sorted(anim_lower)))

if __name__=='__main__': main()
