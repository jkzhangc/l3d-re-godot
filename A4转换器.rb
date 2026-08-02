# va图块转new格式

# 单图块大小
$tile_width = 32
$tile_height = 32

$tile_w_index = 5 # 要转换的图块组横索引
$tile_h_index = 1 # 要转换的图块组纵索引
sprite = Sprite.new
sprite.oy = 128/2
sprite.y = Graphics.height/2
sprite.bitmap = Bitmap.new(544,128)
sprite.bitmap.draw_text(sprite.bitmap.rect, "正在转换", 1)

newbitmap = Bitmap.new(512,480)
bitmap = Cache.tileset("TileA4-Tw.png")
Graphics.update

# 屋顶单个
x,y = 0,0
tilex = 64*$tile_w_index
tiley = 160*$tile_h_index
p tilex,tiley
src_rect = Rect.new(tilex,tiley,$tile_width,$tile_height)
newbitmap.blt(x, y, bitmap, src_rect)

# 屋顶四个边角
x += 32
tilex += 32
src_rect = Rect.new(tilex,tiley,$tile_width,$tile_height)
newbitmap.blt(x, y, bitmap, src_rect)

# 屋顶左上
x = 0
y += 32
tilex -= 32
tiley += 32
src_rect = Rect.new(tilex,tiley,$tile_width,$tile_height)
newbitmap.blt(x, y, bitmap, src_rect)

# 屋顶中上
x += 32
tilex += 16
src_rect = Rect.new(tilex,tiley,16,32)
newbitmap.blt(x, y, bitmap, src_rect)
x += 16
tilex += 16
src_rect = Rect.new(tilex,tiley,16,32)
newbitmap.blt(x, y, bitmap, src_rect)

# 屋顶右上
x += 16
#~ tilex += 16
src_rect = Rect.new(tilex,tiley,$tile_width,$tile_height)
newbitmap.blt(x, y, bitmap, src_rect)

# 屋顶左中
x = 0
y += 32
tilex -= 32
tiley += 16
src_rect = Rect.new(tilex,tiley,$tile_width,16)
newbitmap.blt(x, y, bitmap, src_rect)
y += 16
tiley += 16
src_rect = Rect.new(tilex,tiley,$tile_width,16)
newbitmap.blt(x, y, bitmap, src_rect)

# 屋顶左下
y += 16
src_rect = Rect.new(tilex,tiley,$tile_width,$tile_height)
newbitmap.blt(x, y, bitmap, src_rect)

# 屋顶中下
x += 32
tilex += 16
src_rect = Rect.new(tilex,tiley,16,$tile_height)
newbitmap.blt(x, y, bitmap, src_rect)
x += 16
tilex += 16
src_rect = Rect.new(tilex,tiley,16,$tile_height)
newbitmap.blt(x, y, bitmap, src_rect)


# 屋顶右下
x += 16
src_rect = Rect.new(tilex,tiley,$tile_width,$tile_height)
newbitmap.blt(x, y, bitmap, src_rect)

# 屋顶右中
y -= 16
src_rect = Rect.new(tilex,tiley,$tile_width,16)
newbitmap.blt(x, y, bitmap, src_rect)
y -= 16
tiley -= 16
src_rect = Rect.new(tilex,tiley,$tile_width,16)
newbitmap.blt(x, y, bitmap, src_rect)

# 屋顶中
tilex -= 16
x -= 32
p "屋顶中",tilex,tiley
src_rect = Rect.new(tilex,tiley,$tile_width,$tile_height)
newbitmap.blt(x, y, bitmap, src_rect)

# ============================================================
# 边角 16 种变体 — 4×4 网格
# 每个角可独立显示/隐藏 roofline，共 2^4 = 16 种组合
# 列编码 TL/TR，行编码 BL/BR：
#         col0(无顶角) col1(TL)  col2(TR)  col3(TL+TR)
# row0(无底角):  NONE      TL        TR        TL+TR
# row1(BL):      BL        TL+BL     TR+BL     TL+TR+BL
# row2(BR):      BR        TL+BR     TR+BR     TL+TR+BR
# row3(BL+BR):   BL+BR     TL+BL+BR  TR+BL+BR  ALL4
# ============================================================

base_src_x = 64 * $tile_w_index + 16   # 墙壁基底 x
base_src_y = 160 * $tile_h_index + 48  # 墙壁基底 y
corner_x = 64 * $tile_w_index + 32     # 屋顶四边角 tile 的 x（取四角碎片）
corner_y = 160 * $tile_h_index         # 屋顶四边角 tile 的 y

grid_x = 32 * 3   # = 96
grid_y = 32        # = 32

4.times do |col|
  4.times do |row|
    has_tl = (col & 1) != 0
    has_tr = (col & 2) != 0
    has_bl = (row & 1) != 0
    has_br = (row & 2) != 0

    x = grid_x + col * 32
    y = grid_y + row * 32

    # 1. 画基底（无 roofline 的墙壁）
    src_rect = Rect.new(base_src_x, base_src_y, 32, 32)
    newbitmap.blt(x, y, bitmap, src_rect)

    # 2. 叠加激活的角碎片（16×16）
    if has_tl
      src_rect = Rect.new(corner_x, corner_y, 16, 16)
      newbitmap.blt(x, y, bitmap, src_rect)
    end
    if has_tr
      src_rect = Rect.new(corner_x + 16, corner_y, 16, 16)
      newbitmap.blt(x + 16, y, bitmap, src_rect)
    end
    if has_bl
      src_rect = Rect.new(corner_x, corner_y + 16, 16, 16)
      newbitmap.blt(x, y + 16, bitmap, src_rect)
    end
    if has_br
      src_rect = Rect.new(corner_x + 16, corner_y + 16, 16, 16)
      newbitmap.blt(x + 16, y + 16, bitmap, src_rect)
    end
  end
end

# ============================================================
# 墙壁 3×3 网格（纯墙壁，无 roofline）— 源行3-4
# 合成"中上/左中/中/右中/中下"，与屋顶 3×3 结构一致
# ============================================================
wx = 64 * $tile_w_index   # 320
wy = 160 * $tile_h_index  # 160
wally = 32 * 4  # = 128

# 墙壁TL
src_rect = Rect.new(wx, wy + 96, 32, 32)
newbitmap.blt(0, wally, bitmap, src_rect)

# 墙壁中上: 右半 墙壁TL + 左半 墙壁TR
src_rect = Rect.new(wx + 16, wy + 96, 16, 32)
newbitmap.blt(32, wally, bitmap, src_rect)
src_rect = Rect.new(wx + 32, wy + 96, 16, 32)
newbitmap.blt(48, wally, bitmap, src_rect)

# 墙壁TR
src_rect = Rect.new(wx + 32, wy + 96, 32, 32)
newbitmap.blt(64, wally, bitmap, src_rect)

# 墙壁左中: 下半 墙壁TL + 上半 墙壁BL
wally += 32
src_rect = Rect.new(wx, wy + 112, 32, 16)
newbitmap.blt(0, wally, bitmap, src_rect)
src_rect = Rect.new(wx, wy + 128, 32, 16)
newbitmap.blt(0, wally + 16, bitmap, src_rect)

# 墙壁中: 四个墙壁的交界 32×32
src_rect = Rect.new(wx + 16, wy + 112, 32, 32)
newbitmap.blt(32, wally, bitmap, src_rect)

# 墙壁右中: 下半 墙壁TR + 上半 墙壁BR
src_rect = Rect.new(wx + 32, wy + 112, 32, 16)
newbitmap.blt(64, wally, bitmap, src_rect)
src_rect = Rect.new(wx + 32, wy + 128, 32, 16)
newbitmap.blt(64, wally + 16, bitmap, src_rect)

# 墙壁BL
wally += 32
src_rect = Rect.new(wx, wy + 128, 32, 32)
newbitmap.blt(0, wally, bitmap, src_rect)

# 墙壁中下: 右半 墙壁BL + 左半 墙壁BR
src_rect = Rect.new(wx + 16, wy + 128, 16, 32)
newbitmap.blt(32, wally, bitmap, src_rect)
src_rect = Rect.new(wx + 32, wy + 128, 16, 32)
newbitmap.blt(48, wally, bitmap, src_rect)

# 墙壁BR
src_rect = Rect.new(wx + 32, wy + 128, 32, 32)
newbitmap.blt(64, wally, bitmap, src_rect)

# ============================================================
# 内角 4 种（凹角 — wall wraps around empty quadrant）
# 每个内角 = 两个 roof 象限(带 roofline 的内壁) + 两个墙象限
# 内角 TL: empty=TL, wall=TR+BL+BR
#    TR(16,0): 从 屋顶TR 取 top-left 16×16 → roofline 朝上
#    BL(0,16): 从 屋顶BL 取 top-left 16×16 → roofline 朝左
#    BR(16,16): 纯墙壁
#    TL(0,0): 纯墙壁（外侧）
# ============================================================

# 屋顶 tile 内部墙面（无 roofline 可见），取 屋顶TL 右下 16×16
rw_x = wx + 16   # 336
rw_y = wy + 48   # 208

ic_x = 0
ic_y = 32 * 7  # = 224 (墙壁 3×3 占 y=128..224)

# --- 内角 TL (empty=TL) ---
# TR 象限: 屋顶TR(352,192) top-left 16×16 (roofline 朝上)
src_rect = Rect.new(wx + 32, wy + 32, 16, 16)
newbitmap.blt(ic_x + 16, ic_y, bitmap, src_rect)
# BL 象限: 屋顶BL(320,224) top-left 16×16 (roofline 朝左)
src_rect = Rect.new(wx, wy + 64, 16, 16)
newbitmap.blt(ic_x, ic_y + 16, bitmap, src_rect)
# BR+TL 象限: 屋顶内墙面 (纯墙，无 roofline)
src_rect = Rect.new(rw_x, rw_y, 16, 16)
newbitmap.blt(ic_x + 16, ic_y + 16, bitmap, src_rect)
newbitmap.blt(ic_x, ic_y, bitmap, src_rect)

# --- 内角 TR (empty=TR) ---
ic_x += 32
# TL 象限: 屋顶TL(320,192) top-right 16×16 (roofline 朝上+左)
src_rect = Rect.new(wx + 16, wy + 32, 16, 16)
newbitmap.blt(ic_x, ic_y, bitmap, src_rect)
# BR 象限: 屋顶BR(352,224) bottom-left 16×16 (roofline 朝右+下)
src_rect = Rect.new(wx + 32, wy + 80, 16, 16)
newbitmap.blt(ic_x + 16, ic_y + 16, bitmap, src_rect)
# BL+TR 象限: 屋顶内墙面
src_rect = Rect.new(rw_x, rw_y, 16, 16)
newbitmap.blt(ic_x, ic_y + 16, bitmap, src_rect)
newbitmap.blt(ic_x + 16, ic_y, bitmap, src_rect)

# --- 内角 BL (empty=BL) ---
ic_x += 32
# TL 象限: 屋顶TL(320,192) bottom-left 16×16 (roofline 朝上+左)
src_rect = Rect.new(wx, wy + 48, 16, 16)
newbitmap.blt(ic_x, ic_y, bitmap, src_rect)
# BR 象限: 屋顶BR(352,224) top-right 16×16 (roofline 朝右+下)
src_rect = Rect.new(wx + 48, wy + 64, 16, 16)
newbitmap.blt(ic_x + 16, ic_y + 16, bitmap, src_rect)
# TR+BL 象限: 屋顶内墙面
src_rect = Rect.new(rw_x, rw_y, 16, 16)
newbitmap.blt(ic_x + 16, ic_y, bitmap, src_rect)
newbitmap.blt(ic_x, ic_y + 16, bitmap, src_rect)

# --- 内角 BR (empty=BR) ---
ic_x += 32
# TR 象限: 屋顶TR(352,192) bottom-right 16×16 (roofline 朝上+右)
src_rect = Rect.new(wx + 48, wy + 48, 16, 16)
newbitmap.blt(ic_x + 16, ic_y, bitmap, src_rect)
# BL 象限: 屋顶BL(320,224) bottom-right 16×16 (roofline 朝左+下)
src_rect = Rect.new(wx + 16, wy + 80, 16, 16)
newbitmap.blt(ic_x, ic_y + 16, bitmap, src_rect)
# TL+BR 象限: 屋顶内墙面
src_rect = Rect.new(rw_x, rw_y, 16, 16)
newbitmap.blt(ic_x, ic_y, bitmap, src_rect)
newbitmap.blt(ic_x + 16, ic_y + 16, bitmap, src_rect)

# ============================================================
# 屋顶边缘变体（全部用屋顶 tile 合成）
# ============================================================

# 辅助: 用 16×16 屋顶内墙面填充 32×16 横条
def fill_wall_h(newbitmap, bitmap, rw_x, rw_y, dst_x, dst_y)
  src_rect = Rect.new(rw_x, rw_y, 16, 16)
  newbitmap.blt(dst_x, dst_y, bitmap, src_rect)
  newbitmap.blt(dst_x + 16, dst_y, bitmap, src_rect)
end

# 辅助: 用 16×16 屋顶内墙面填充 16×32 竖条
def fill_wall_v(newbitmap, bitmap, rw_x, rw_y, dst_x, dst_y)
  src_rect = Rect.new(rw_x, rw_y, 16, 16)
  newbitmap.blt(dst_x, dst_y, bitmap, src_rect)
  newbitmap.blt(dst_x, dst_y + 16, bitmap, src_rect)
end

# --- 平行边 (2 边相对) ---
ev_x = 32 * 3   # = 96
ev_y = 32 * 8   # = 256

# 仅顶+底 (水平带): 屋顶-单 底图 + 左右贴屋顶内墙面
src_rect = Rect.new(wx, wy, 32, 32)  # 屋顶-单
newbitmap.blt(ev_x, ev_y, bitmap, src_rect)
fill_wall_v(newbitmap, bitmap, rw_x, rw_y, ev_x, ev_y)
fill_wall_v(newbitmap, bitmap, rw_x, rw_y, ev_x + 16, ev_y)

# 仅左+右 (垂直带)
ev_x += 32
src_rect = Rect.new(wx, wy, 32, 32)
newbitmap.blt(ev_x, ev_y, bitmap, src_rect)
fill_wall_h(newbitmap, bitmap, rw_x, rw_y, ev_x, ev_y)
fill_wall_h(newbitmap, bitmap, rw_x, rw_y, ev_x, ev_y + 16)

# --- T 形 (3 边有 roofline，缺一边) ---
ev_x = 32 * 5   # = 160
ev_y = 32 * 8   # = 256

# 屋顶-四边角 的坐标
roof_all_x = wx + 32  # 352
roof_all_y = wy        # 160

# 缺顶 (底+左+右): 四边角底 + 顶部贴屋顶内墙面
src_rect = Rect.new(roof_all_x, roof_all_y, 32, 32)
newbitmap.blt(ev_x, ev_y, bitmap, src_rect)
fill_wall_h(newbitmap, bitmap, rw_x, rw_y, ev_x, ev_y)

# 缺底 (顶+左+右)
ev_x += 32
src_rect = Rect.new(roof_all_x, roof_all_y, 32, 32)
newbitmap.blt(ev_x, ev_y, bitmap, src_rect)
fill_wall_h(newbitmap, bitmap, rw_x, rw_y, ev_x, ev_y + 16)

# 缺左 (顶+右+底)
ev_x += 32
src_rect = Rect.new(roof_all_x, roof_all_y, 32, 32)
newbitmap.blt(ev_x, ev_y, bitmap, src_rect)
fill_wall_v(newbitmap, bitmap, rw_x, rw_y, ev_x, ev_y)

# 缺右 (顶+左+底)
ev_x += 32
src_rect = Rect.new(roof_all_x, roof_all_y, 32, 32)
newbitmap.blt(ev_x, ev_y, bitmap, src_rect)
fill_wall_v(newbitmap, bitmap, rw_x, rw_y, ev_x + 16, ev_y)

# 将newbitmap保存为png。
surface = newbitmap.create_surface
if surface
  surface.save_png("A4-new.png")
end

loop do
  sprite.bitmap = newbitmap
  Graphics.update
  break if Input.press?(:C)
end
exit
