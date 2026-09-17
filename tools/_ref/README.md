# _ref —— 参考转换器与运行时探针（仅用于实证，不进入生产流程）

本目录保存「RM2K3 → MV 素材转换器」的原始资料，以及用于判定其坐标语义的运行时探针。
结论见 `../rm2k3_map_restore/RM2K3到VX_Ace图块转换说明.md` 的「参考转换器公布版本的坐标缺陷」。

| 文件 | 说明 |
|---|---|
| `converter_original.html` | 从 `https://krmbn0576.github.io/rpgmakermv/converter.html` 下载的**原始**页面（45KB，无内嵌样例图） |
| `samples/` | 从本地保存的带翻译标记副本中提取的文档内嵌 golden 样例图（8 张，含 A1/A2/A5/B 与 おまけ C/D/E/动画） |
| `_ref_convert.js` | 从原始页面提取的 `transparent` / `dot2x` / `dot3x` / `convertChipset` 函数体，仅把 `data: canvas.toDataURL()` 换成 `snap: snapshotCanvas(canvas)` 以便取出像素 |
| `run_ref.js` | Node 探针：以**规范精确**的 `putImageData` / canvas 重置语义执行上述原始代码 |
| `refprobe_output/` | 探针输出结果（**几乎全空**——即公布代码的缺陷证据） |
| `evidence/` | 本项目新管道的可视化证据（variant 全图案表、水体/瀑布动画帧） |

## 重跑探针

```bash
# 1) 由芯片组 PNG 生成原始 RGBA（与项目解码规则一致：索引 0 → alpha 0）
python make_chip_rgba.py "../rm2k3_map_restore/奨3.png"

# 2) 运行原始转换器
"C:/Users/Administrator/.workbuddy/binaries/node/versions/22.22.2-2/node.exe" run_ref.js
#    → 写出 raw_<i>.rgba + raw_manifest.json
```

`raw_*.rgba` 与 `chip.rgba` 是可随时重新生成的中间产物，不入库。

## 关键发现

原始 JS 把落点写成 `(dx - sx)`，实测多数调用点算出**负坐标**被画布裁掉：
A5 / B 整张全空，A1 仅余 4 列细条，C/D/E 只剩左上角残缺（见 `refprobe_output/`）。
而 `samples/` 里的文档样例是完整的，且其占位与「目标 = (dx, dy)」逐一吻合，
说明公布版本已回归、文档样例来自更早的正确版本。生产实现按 golden 语义编写。
