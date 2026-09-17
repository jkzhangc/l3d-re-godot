// 参考实现运行时探针：以规范精确的 putImageData 语义执行原网页转换器的
// convertChipset()，用于判定其 (dx - sx) 坐标公式的真实落点。
// 仅测试用，不进入生产流程。
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const CHIP_W = 480, CHIP_H = 256, CHIP_SIZE = 2;
const chip = {
  width: CHIP_W, height: CHIP_H,
  data: new Uint8ClampedArray(fs.readFileSync(path.join(__dirname, 'chip.rgba'))),
};

function makeCanvas() {
  // 真实 canvas 语义：设置 width/height 会重置并清空位图（参考实现依赖此行为）
  let W = 300, H = 150, buf = new Uint8ClampedArray(W * H * 4);
  const canvas = {
    get width() { return W; },
    set width(v) { W = v | 0; buf = new Uint8ClampedArray(W * H * 4); },
    get height() { return H; },
    set height(v) { H = v | 0; buf = new Uint8ClampedArray(W * H * 4); },
    get _buf() { return buf; },
  };
  canvas.getContext = () => {
    const alloc = () => { buf = new Uint8ClampedArray(W * H * 4); };
    return {
      clearRect() { alloc(); },
      drawImage(img) {
        alloc();
        const w = Math.min(img.width, W), h = Math.min(img.height, H);
        for (let r = 0; r < h; r++) for (let c = 0; c < w; c++) {
          const s = (r * img.width + c) * 4, d = (r * W + c) * 4;
          buf[d] = img.data[s]; buf[d + 1] = img.data[s + 1];
          buf[d + 2] = img.data[s + 2]; buf[d + 3] = img.data[s + 3];
        }
      },
      getImageData(x, y, w, h) {
        const out = new Uint8ClampedArray(w * h * 4);
        for (let r = 0; r < h; r++) for (let c = 0; c < w; c++) {
          const s = ((y + r) * W + (x + c)) * 4, d = (r * w + c) * 4;
          out[d] = buf[s]; out[d + 1] = buf[s + 1];
          out[d + 2] = buf[s + 2]; out[d + 3] = buf[s + 3];
        }
        return { width: w, height: h, data: out };
      },
      createImageData(w, h) { return { width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }; },
      fillRect(x, y, w, h) {
        for (let r = Math.max(0, y | 0); r < Math.min(H, y + h); r++)
          for (let c = Math.max(0, x | 0); c < Math.min(W, x + w); c++) {
            const d = (r * W + c) * 4;
            buf[d] = 0; buf[d + 1] = 0; buf[d + 2] = 0; buf[d + 3] = 255;
          }
      },
      // 规范语义：dirty 矩形取自 imageData；写入画布位置 = dx + (clippedX - dirtyX)
      putImageData(imageData, dx, dy, dirtyX, dirtyY, dirtyWidth, dirtyHeight) {
        if (dirtyWidth < 0) { dirtyX += dirtyWidth; dirtyWidth = -dirtyWidth; }
        if (dirtyHeight < 0) { dirtyY += dirtyHeight; dirtyHeight = -dirtyHeight; }
        dx |= 0; dy |= 0; dirtyX = dirtyX | 0; dirtyY = dirtyY | 0;
        dirtyWidth = dirtyWidth | 0; dirtyHeight = dirtyHeight | 0;
        if (dirtyWidth === 0 || dirtyHeight === 0) return;
        let sx = dirtyX, sy = dirtyY, sw = dirtyWidth, sh = dirtyHeight;
        let offX = 0, offY = 0;
        if (sx < 0) { offX = -sx; sw += sx; sx = 0; }
        if (sy < 0) { offY = -sy; sh += sy; sy = 0; }
        sw = Math.min(sw, imageData.width - sx);
        sh = Math.min(sh, imageData.height - sy);
        if (sw <= 0 || sh <= 0) return;
        for (let r = 0; r < sh; r++) for (let c = 0; c < sw; c++) {
          const X = dx + c + offX, Y = dy + r + offY;
          if (X < 0 || Y < 0 || X >= W || Y >= H) continue;
          const s = ((sy + r) * imageData.width + (sx + c)) * 4;
          const d = (Y * W + X) * 4;
          buf[d] = imageData.data[s]; buf[d + 1] = imageData.data[s + 1];
          buf[d + 2] = imageData.data[s + 2]; buf[d + 3] = imageData.data[s + 3];
        }
      },
    };
  };
  return canvas;
}

const sandbox = {
  document: { createElement: () => makeCanvas() },
  options: { chipSize: CHIP_SIZE, autotile: true, animation: false },
  console,
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(__dirname, '_ref_convert.js'), 'utf8'), sandbox);
const tilesets = vm.runInContext('convertChipset', sandbox)(chip);

const manifest = [];
tilesets.forEach((ts, i) => {
  const cv = ts.snap;
  fs.writeFileSync(path.join(__dirname, `raw_${i}.rgba`), Buffer.from(cv.buf));
  manifest.push({
    i, desc: ts.desc, w: cv.width, h: cv.height,
    tiles: [cv.width / (16 * CHIP_SIZE), cv.height / (16 * CHIP_SIZE)],
  });
});
fs.writeFileSync(path.join(__dirname, 'raw_manifest.json'), JSON.stringify(manifest, null, 2));
console.log(manifest.map(o => `${o.i} ${o.w}x${o.h} tiles=${o.tiles} ${o.desc}`).join('\n'));
