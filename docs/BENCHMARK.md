# 效能量測指南

`--bench` 以固定工作量渲染，每個像素嘗試取樣 `spp` 次，單條路徑的深度上限為 32。程式會在整張圖完成後輸出一行 `BENCH` 結果。

## 執行

從專案根目錄編譯並執行。

```sh
CC=gcc ./makeMakefile.sh example.c > Makefile
make all
./bin/pathTracing --bench --scene scenes/example.txt --spp 64 --threads 20 --seed 42 --out out.txt --out-xyz out.xyz
```

| 參數 | 用途 | 預設 |
| --- | --- | --- |
| `--bench` | 啟用 benchmark 模式 | — |
| `--scene FILE` | 載入場景檔 | `example.c` 的內建場景 |
| `--width N`、`--height N` | 搭配 `--scene` 覆蓋影像解析度 | 場景檔指定的寬、高 |
| `--spp N` | 每像素取樣數 | 64 |
| `--threads N` | CPU 渲染執行緒數 | 1 |
| `--seed N` | 亂數種子 | 42 |
| `--out FILE` | 輸出 8-bit 顯示圖文字檔 | — |
| `--out-xyz FILE` | 輸出線性 XYZ 二進位檔 | — |

場景檔的語法見 [場景檔格式](SCENE_FORMAT.md)。

## 輸出

```text
BENCH width=720 height=480 spp=64 maxDepth=32 threads=20 seed=42 time_s=... Msamples_per_s=...
```

- `time_s` 是渲染耗時（秒）。計時區間從開始到完成取樣，場景載入、光譜表初始化與寫檔在區間之外。
- `Msamples_per_s` 是每秒處理的百萬個樣本數，計算方式為 `width × height × spp / time_s / 10⁶`。
- `out.txt` 的第一行是寬和高，接下來每行是一個打包的像素值。使用 [toImg.py](../toImg.py) 可將它轉成 PNG。
- `out.xyz` 先寫入寬和高（各一個 `int32`），接著每個像素依序寫入 X、Y、Z（各一個 `float64`）。兩種影像輸出都從最上列開始，每列由左向右。

轉圖與分析使用 [requirements.txt](../requirements.txt) 所列的 Python 套件。

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python toImg.py out.txt out.png
```

## 量測腳本

兩個腳本都使用內建場景。從專案根目錄執行，並先完成上面的編譯步驟。

### 掃描執行緒數

```sh
./bench.sh 64 5 42
```

[bench.sh](../bench.sh) 的三個參數依序是 SPP、每組重複次數和種子，預設為 64、5、42。上例固定工作量，以不同執行緒數各跑 5 次，將每次結果寫入 `benchResults.csv`，並在終端機列出各組耗時的中位數。

### 掃描每像素取樣數

```sh
./sppSweep.sh
.venv/bin/python analyzeSpp.py sppSweep
```

[sppSweep.sh](../sppSweep.sh) 先產生兩張使用不同種子的參考圖，再以 1、2、4 等 SPP 渲染測試圖。預設輸出至 `sppSweep/`，其中 `timings.csv` 記錄各組耗時，`ref.xyz`、`ref2.xyz` 和 `img_spp*.xyz` 是供比較的線性影像。可用 `REF_SPP`、`MAX_SPP`、`RUNS`、`THREADS`、`SEED`、`REF_SEED`、`REF_SEED2`、`PIN_SINGLE` 和 `OUTDIR` 調整設定。

[analyzeSpp.py](../analyzeSpp.py) 以兩張參考圖的平均值為基準，比較各 SPP 的線性 XYZ 誤差與耗時，輸出 `summary.csv` 和圖表 `sppSweep.png`。
