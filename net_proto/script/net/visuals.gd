class_name NetVisuals
## 原型可视化工具 —— 纯表现，不包含任何游戏逻辑。
## 方块贴图用于替代正式美术，方便快速验证同步。

static func square_texture(color: Color, size: int) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)
