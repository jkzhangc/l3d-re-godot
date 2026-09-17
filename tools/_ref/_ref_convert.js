function transparent(imageData, point) {
            var data = imageData.data;

            for (var y = 0; y < imageData.height; y++) {
                for (var x = 0; x < imageData.width; x++) {
                    var i = (x + y * imageData.width) * 4;
                    if (data[i] === data[point + 0] && data[i + 1] === data[point + 1] && data[i + 2] === data[point + 2]) {
                        data[i + 3] = 0;
                    }
                }
            }
        }

		
function snapshotCanvas(canvas) {
    return { width: canvas.width, height: canvas.height,
             buf: canvas._buf.slice(0, canvas.width * canvas.height * 4) };
}
function dot2x(input, output) {
    var inputData = new Uint32Array(input.data.buffer);
    var outputData = new Uint32Array(output.data.buffer);
    for (var y = 0; y < input.height; y++) {
        for (var x = 0; x < input.width; x++) {
            var i = (x + y * input.width * 2) * 2;
            outputData[i] = outputData[i + 1] = outputData[i + input.width * 2] =
            outputData[i + 1 + input.width * 2] = inputData[x + y * input.width];
        }
    }
}
function dot3x(input, output) {
    var inputData = new Uint32Array(input.data.buffer);
    var outputData = new Uint32Array(output.data.buffer);
    for (var y = 0; y < input.height; y++) {
        for (var x = 0; x < input.width; x++) {
            var i = (x + y * input.width * 3) * 3;
            outputData[i] = outputData[i + 1] = outputData[i + 2] = outputData[i + input.width * 3] =
            outputData[i + 1 + input.width * 3] = outputData[i + 2 + input.width * 3] =
            outputData[i + input.width * 6] = outputData[i + 1 + input.width * 6] =
            outputData[i + 2 + input.width * 6] = inputData[x + y * input.width];
        }
    }
}

function convertChipset(image) {
            function putHalfTile(dx, dy, sx, sy) {
                ctx.putImageData(imageData, (dx - sx) * tileSize, (dy - sy) * tileSize, sx * tileSize, sy * tileSize, tileSize / 2, tileSize / 2);
            }

            function putFullTile(dx, dy, sx, sy) {
                ctx.putImageData(imageData, (dx - sx) * tileSize, (dy - sy) * tileSize, sx * tileSize, sy * tileSize, tileSize, tileSize);
            }

            function putRectangle(dx, dy, sx, sy, sw, sh) {
                ctx.putImageData(imageData, (dx - sx) * tileSize, (dy - sy) * tileSize, sx * tileSize, sy * tileSize, tileSize * sw, tileSize * sh);
            }

            function putCircle(dx, dy, sx, sy) {
                putHalfTile(dx + 0.5, dy + 0.5, sx + 2.5, sy + 0.5);
                putHalfTile(dx + 1, dy + 0.5, sx + 2, sy + 0.5);
                putHalfTile(dx + 0.5, dy + 1, sx + 2.5, sy + 0);
                putHalfTile(dx + 1, dy + 1, sx + 2, sy + 0);
            }

            function putAutoTile(dx, dy, sx, sy) {
                putFullTile(dx + 0, dy + 0, sx + 0, sy + 0);
                putFullTile(dx + 1, dy + 0, sx + 2, sy + 0);
                //角優先に選別、中央に装飾などがある場合失われる
                //2000規格でも2x2にタイルを置いた時のために一応角同士がつながるようになっているため、角優先を採用
                putFullTile(dx + 0, dy + 1, sx + 0, sy + 1);
                putFullTile(dx + 1, dy + 1, sx + 2, sy + 1);
                putFullTile(dx + 0, dy + 2, sx + 0, sy + 3);
                putFullTile(dx + 1, dy + 2, sx + 2, sy + 3);
                //中央優先に選別、角に装飾などがある場合失われる
                /*putHalfTile(dx + 0, dy + 1, sx + 0, sy + 1);
                putHalfTile(dx + 0.5, dy + 1, sx + 1.5, sy + 1);
                putHalfTile(dx + 1, dy + 1, sx + 1, sy + 1);
                putHalfTile(dx + 1.5, dy + 1, sx + 2.5, sy + 1);
                putHalfTile(dx + 0, dy + 1.5, sx + 0, sy + 2.5);
                putHalfTile(dx + 0.5, dy + 1.5, sx + 1.5, sy + 2.5);
                putHalfTile(dx + 1, dy + 1.5, sx + 1, sy + 2.5);
                putHalfTile(dx + 1.5, dy + 1.5, sx + 2.5, sy + 2.5);
                putHalfTile(dx + 0, dy + 2, sx + 0, sy + 2);
                putHalfTile(dx + 0.5, dy + 2, sx + 1.5, sy + 2);
                putHalfTile(dx + 1, dy + 2, sx + 1, sy + 2);
                putHalfTile(dx + 1.5, dy + 2, sx + 2.5, sy + 2);
                putHalfTile(dx + 0, dy + 2.5, sx + 0, sy + 3.5);
                putHalfTile(dx + 0.5, dy + 2.5, sx + 1.5, sy + 3.5);
                putHalfTile(dx + 1, dy + 2.5, sx + 1, sy + 3.5);
                putHalfTile(dx + 1.5, dy + 2.5, sx + 2.5, sy + 3.5);*/
            }

            function putAllAutoTile(dx, dy, sx, sy) {
                putRectangle(dx + 0, dy + 0, sx + 0, sy + 0, 3, 4);
                putHalfTile(dx + 1, dy + 0, sx + 0, sy + 1);
                putHalfTile(dx + 1.5, dy + 0, sx + 2.5, sy + 1);
                putHalfTile(dx + 1, dy + 0.5, sx + 0, sy + 3.5);
                putHalfTile(dx + 1.5, dy + 0.5, sx + 2.5, sy + 3.5);
                putFullTile(dx + 0, dy + 4, sx + 1, sy + 2);
                putFullTile(dx + 1, dy + 4, sx + 1, sy + 2);
                putFullTile(dx + 2, dy + 4, sx + 1, sy + 2);
                putFullTile(dx + 0, dy + 5, sx + 1, sy + 2);
                putFullTile(dx + 1, dy + 5, sx + 1, sy + 2);
                putFullTile(dx + 2, dy + 5, sx + 1, sy + 2);
                putHalfTile(dx + 0, dy + 4.5, sx + 2, sy + 0.5);
                putHalfTile(dx + 0, dy + 5, sx + 2, sy + 0);
                putHalfTile(dx + 0.5, dy + 4.5, sx + 2.5, sy + 0.5);
                putHalfTile(dx + 0.5, dy + 5, sx + 2.5, sy + 0);
                putHalfTile(dx + 1.5, dy + 4, sx + 2.5, sy + 0);
                putHalfTile(dx + 1.5, dy + 4.5, sx + 2.5, sy + 0.5);
                putHalfTile(dx + 2, dy + 4, sx + 2, sy + 0);
                putHalfTile(dx + 2, dy + 4.5, sx + 2, sy + 0.5);
                putHalfTile(dx + 1, dy + 5.5, sx + 2, sy + 0.5);
                putHalfTile(dx + 1.5, dy + 5, sx + 2.5, sy + 0);
                putHalfTile(dx + 2, dy + 5, sx + 2, sy + 0);
                putHalfTile(dx + 2.5, dy + 5.5, sx + 2.5, sy + 0.5);
                putFullTile(dx + 3, dy + 0, sx + 1, sy + 2);
                putFullTile(dx + 4, dy + 0, sx + 1, sy + 2);
                putFullTile(dx + 3, dy + 1, sx + 1, sy + 2);
                putFullTile(dx + 4, dy + 1, sx + 1, sy + 2);
                putCircle(dx + 3, dy + 0, sx, sy);
                putFullTile(dx + 3, dy + 2, sx + 2, sy + 0);
                putFullTile(dx + 4, dy + 2, sx + 2, sy + 0);
                putFullTile(dx + 3, dy + 3, sx + 2, sy + 0);
                putFullTile(dx + 4, dy + 3, sx + 2, sy + 0);
                putHalfTile(dx + 3, dy + 2, sx + 1, sy + 2);
                putHalfTile(dx + 4.5, dy + 2, sx + 1.5, sy + 2);
                putHalfTile(dx + 3, dy + 3.5, sx + 1, sy + 2.5);
                putHalfTile(dx + 4.5, dy + 3.5, sx + 1.5, sy + 2.5);
                putFullTile(dx + 3, dy + 4, sx + 0, sy + 1);
                putFullTile(dx + 4, dy + 4, sx + 2, sy + 1);
                putFullTile(dx + 3, dy + 5, sx + 0, sy + 3);
                putFullTile(dx + 4, dy + 5, sx + 2, sy + 3);
                putCircle(dx + 3, dy + 4, sx, sy);
                putRectangle(dx + 5, dy + 0, sx + 0, sy + 1, 0.5, 3);
                putRectangle(dx + 5.5, dy + 0, sx + 2.5, sy + 1, 0.5, 3);
                putFullTile(dx + 6, dy + 0, sx + 0, sy + 2);
                putFullTile(dx + 6, dy + 1, sx + 0, sy + 2);
                putFullTile(dx + 6, dy + 2, sx + 0, sy + 2);
                putFullTile(dx + 7, dy + 0, sx + 2, sy + 2);
                putFullTile(dx + 7, dy + 1, sx + 2, sy + 2);
                putFullTile(dx + 7, dy + 2, sx + 2, sy + 2);
                putCircle(dx + 6, dy + 0, sx, sy);
                putCircle(dx + 6, dy + 1, sx, sy);
                putRectangle(dx + 5, dy + 3, sx + 0, sy + 1, 3, 0.5);
                putRectangle(dx + 5, dy + 3.5, sx + 0, sy + 3.5, 3, 0.5);
                putFullTile(dx + 5, dy + 4, sx + 1, sy + 1);
                putFullTile(dx + 6, dy + 4, sx + 1, sy + 1);
                putFullTile(dx + 7, dy + 4, sx + 1, sy + 1);
                putFullTile(dx + 5, dy + 5, sx + 1, sy + 3);
                putFullTile(dx + 6, dy + 5, sx + 1, sy + 3);
                putFullTile(dx + 7, dy + 5, sx + 1, sy + 3);
                putCircle(dx + 5, dy + 4, sx, sy);
                putCircle(dx + 6, dy + 4, sx, sy);
            }

            var canvas = document.createElement("canvas");
            var ctx = canvas.getContext("2d");

            canvas.width = image.width;
            canvas.height = image.height;

            ctx.drawImage(image, 0, 0);

            var prevData = ctx.getImageData(0, 0, canvas.width, canvas.height);
            transparent(prevData, (18 + 8 * prevData.width) * 16 * 4);
            var imageData = ctx.createImageData(canvas.width * options.chipSize, canvas.height * options.chipSize);
            switch (options.chipSize) {
                case 1:
                    imageData = prevData;
                    break;
                case 2:
                    dot2x(prevData, imageData);
                    break;
                case 3:
                    dot3x(prevData, imageData);
                    break;
                default:
                    break;
            }

            var tileSize = 16 * options.chipSize;
            var tilesets = [];

            // TileA1 水タイル
            canvas.width = 768 / 3 * options.chipSize;
            canvas.height = 576 / 3 * options.chipSize;

            // TileA1 ブロックA(D) 海タイル Dは深海タイルとの接続が不自然
            var offset = 0;
            do {
                for (var i = 0; i < 3; i++) {
                    var dx = i * 2;
                    var sx = i + offset / 2;
                    putFullTile(dx + 0, offset + 0, sx + 0, 0);
                    putFullTile(dx + 1, offset + 0, sx + 0, 3);
                    putHalfTile(dx + 0, offset + 1, sx + 0, 0);
                    putHalfTile(dx + 0.5, offset + 1, sx + 0.5, 2);
                    putHalfTile(dx + 1, offset + 1, sx + 0, 2);
                    putHalfTile(dx + 1.5, offset + 1, sx + 0.5, 0);
                    putHalfTile(dx + 0, offset + 1.5, sx + 0, 1.5);
                    putHalfTile(dx + 0.5, offset + 1.5, sx - offset / 2 + 0.5, 4.5);
                    putHalfTile(dx + 1, offset + 1.5, sx - offset / 2 + 0, 4.5);
                    putHalfTile(dx + 1.5, offset + 1.5, sx + 0.5, 1.5);
                    putHalfTile(dx + 0, offset + 2, sx + 0, 1);
                    putHalfTile(dx + 0.5, offset + 2, sx - offset / 2 + 0.5, 4);
                    putHalfTile(dx + 1, offset + 2, sx - offset / 2 + 0, 4);
                    putHalfTile(dx + 1.5, offset + 2, sx + 0.5, 1);
                    putHalfTile(dx + 0, offset + 2.5, sx + 0, 0.5);
                    putHalfTile(dx + 0.5, offset + 2.5, sx + 0.5, 2.5);
                    putHalfTile(dx + 1, offset + 2.5, sx + 0, 2.5);
                    putHalfTile(dx + 1.5, offset + 2.5, sx + 0.5, 0.5);
                }
                offset += 6;
            } while (offset === 6);

            // TileA1 ブロックB 深海タイル
            for (var i = 0; i < 3; i++) {
                var dx = i * 2;
                var sx = i;
                putFullTile(dx + 0, 3, sx + 0, 6);
                putFullTile(dx + 1, 3, sx + 0, 7);
                putFullTile(dx + 0, 4, sx + 0, 7);
                putFullTile(dx + 1, 4, sx + 0, 7);
                putFullTile(dx + 0, 5, sx + 0, 7);
                putFullTile(dx + 1, 5, sx + 0, 7);
                putHalfTile(dx + 0, 4, sx + 0, 6);
                putHalfTile(dx + 1.5, 4, sx + 0.5, 6);
                putHalfTile(dx + 0, 5.5, sx + 0, 6.5);
                putHalfTile(dx + 1.5, 5.5, sx + 0.5, 6.5);
            }

            // TileA1 ブロックE 滝タイル 4コマ目が失われる
            for (var i = 0; i < 3; i++) {
                for (var j = 14; j < 16; j++) {
                    for (var k = 0; k < 3; k++) {
                        putFullTile(j, k + i * 3, i + 3, k + 4);
                    }
                }
            }

            tilesets.push({ desc: 'A1 水タイル', snap: snapshotCanvas(canvas) });

            // TileA2 ブロックAのみ オートタイル 親パターンが失われるため、一部オートタイル間の接続が不自然
            canvas.width = 768 / 3 * options.chipSize;
            canvas.height = 576 / 3 * options.chipSize;

            putAutoTile(0, 0, 0, 8);
            putAutoTile(2, 0, 3, 8);
            putAutoTile(4, 0, 0, 12);
            putAutoTile(6, 0, 3, 12);
            putAutoTile(0, 3, 6, 0);
            putAutoTile(2, 3, 9, 0);
            putAutoTile(4, 3, 6, 4);
            putAutoTile(6, 3, 9, 4);
            putAutoTile(0, 6, 6, 8);
            putAutoTile(2, 6, 9, 8);
            putAutoTile(4, 6, 6, 12);
            putAutoTile(6, 6, 9, 12);
            ctx.fillRect(8 * tileSize, 0 * tileSize, 8 * tileSize, 12 * tileSize);

            tilesets.push({ desc: 'A2 オートタイル', snap: snapshotCanvas(canvas) });

            // TileA5 通常下層タイル
            canvas.width = 384 / 3 * options.chipSize;
            canvas.height = 768 / 3 * options.chipSize;

            putRectangle(0, 0, 12, 0, 6, 16);
            putRectangle(6, 0, 18, 0, 2, 8);
            putRectangle(6, 8, 20, 0, 2, 8);

            tilesets.push({ desc: 'A5 下層タイル（通常）', snap: snapshotCanvas(canvas) });

            // TileB 上層タイル＋通常下層タイルの残り
            canvas.width = 768 / 3 * options.chipSize;
            canvas.height = 768 / 3 * options.chipSize;

            putRectangle(0, 0, 18, 8, 6, 8);
            putRectangle(0, 8, 24, 0, 6, 8);
            putRectangle(8, 0, 24, 8, 6, 8);
            putRectangle(8, 8, 18, 0, 6, 8);

            tilesets.push({ desc: 'B 上層タイル＋下層タイル（通常）の残り', snap: snapshotCanvas(canvas) });

            // おまけ オートタイル全パターン
            if (options.autotile) {
                canvas.width = 768 / 3 * options.chipSize;
                canvas.height = 768 / 3 * options.chipSize;

                putAllAutoTile(0, 0, 0, 8);
                putAllAutoTile(0, 8, 3, 8);
                putAllAutoTile(8, 0, 0, 12);
                putAllAutoTile(8, 8, 3, 12);

                tilesets.push({ desc: '（おまけ） C オートタイル全パターン', snap: snapshotCanvas(canvas) });

                canvas.width = 768 / 3 * options.chipSize;
                canvas.height = 768 / 3 * options.chipSize;

                putAllAutoTile(0, 0, 6, 0);
                putAllAutoTile(0, 8, 9, 0);
                putAllAutoTile(8, 0, 6, 4);
                putAllAutoTile(8, 8, 9, 4);

                tilesets.push({ desc: '（おまけ） D オートタイル全パターン', snap: snapshotCanvas(canvas) });

                canvas.width = 768 / 3 * options.chipSize;
                canvas.height = 768 / 3 * options.chipSize;

                putAllAutoTile(0, 0, 6, 8);
                putAllAutoTile(0, 8, 9, 8);
                putAllAutoTile(8, 0, 6, 12);
                putAllAutoTile(8, 8, 9, 12);

                tilesets.push({ desc: '（おまけ） E オートタイル全パターン', snap: snapshotCanvas(canvas) });
            }

            // !$Animation アニメーション（4コマ目あり） キャラグラ 右回転でアニメーション
            if (options.animation) {
                canvas.width = tileSize * 3;
                canvas.height = tileSize * 4;

                putRectangle(0, 0, 3, 4, 3, 2);
                putRectangle(0, 2, 3, 7, 3, 1);
                putRectangle(0, 3, 3, 6, 3, 1);

                tilesets.push({ desc: '（おまけ） アニメーション（4コマ目あり） ファイル名先頭に!$をつけてキャラクターフォルダへ　右回転でアニメーション', snap: snapshotCanvas(canvas) });
            }

            return tilesets;
        }
