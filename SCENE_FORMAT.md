# 場景檔格式（v1 草案）

> **狀態：v1 已實作**（`src/scene.c`、`src/scene.h`）。`scenes/example.txt` 的渲染結果和 `example.c` 寫死的場景逐位元相同（已用 `cmp` 驗證）。格式有意見請直接改這份文件，或在 PR 上留言。

分支：`scene-file`

---

## 1. 目的

目前的場景寫死在 `example.c`，換場景就要改程式、重新編譯。場景檔把場景描述移到文字檔：

```bash
./bin/pathTracing --bench --spp 64 --threads 20 --scene scenes/example.txt
```

- 組員可以自己出測資，不用改程式。
- CPU 版本和之後的 GPU 版本讀**同一個檔案**，保證兩邊的場景完全相同。
- **沒有指定 `--scene` 時，照舊使用 `example.c` 寫死的場景**，現有的 baseline 不受影響。

---

## 2. 基本語法

```
pathtracer-scene 1              # 第一個有效行一定是格式名稱和版本
resolution 720 480
camera 144 576 172.8 460.8 -160 720
material air air
...
```

| 規則 | 說明 |
|---|---|
| 一行一個指令 | 第一個字是指令名稱，後面是參數，以空白或 tab 分隔 |
| 註解 | `#` 之後到行尾都忽略 |
| 空白行 | 忽略 |
| 必要參數 | 照固定順序寫 |
| 選用參數 | 寫成 `key=value`，順序不限，放在必要參數之後 |
| 向量參數 | 選用參數裡的向量用逗號分隔，**中間不能有空白**：`at=360,240,-336` |
| 點 | 必要參數裡的點寫成三個數字：`x y z` |
| 數字 | 用 C 的 `strtod` 讀，支援 `5e-3`、負數、完整 double 精度 |
| 名稱 | 英數字和底線，大小寫有別，例如 `gemI`、`ground_1` |
| 路徑 | 不能有空白；相對路徑以**專案根目錄**為準（和現有的 CSV、`.obj` 一致） |
| 編碼 | UTF-8（註解可以寫中文） |

---

## 3. 座標系與單位

和原本的程式相同（見 README）：

- **右手座標系**：+x 向右、+y 向上、+z 朝向觀察者（從螢幕往外）。
- **1 單位 = 0.1 mm**。這會影響吸收（Beer 定律）和散射的程度：同樣的材質，物體越大，光在裡面走越遠，顏色越深、散射越多。
- **正面**：從正面看，多邊形的頂點是**逆時針**排列。法線指向正面。
- **內外**：法線指向的那一側是「外側」，另一側是「內側」。介面的 `inside` / `outside` 材質就是依此決定。

---

## 4. 指令一覽

| 指令 | 次數 | 用途 |
|---|---|---|
| `pathtracer-scene 1` | 1，必須是第一行 | 格式名稱和版本 |
| `resolution` | 1，必要 | 輸出解析度 |
| `camera` | 1，必要 | 相機 |
| `material` | 任意 | 定義材質 |
| `interface` | 任意 | 定義介面（內側材質、外側材質、粗糙度） |
| `sphere` | 任意 | 物體：球 |
| `triangle` | 任意 | 物體：三角形 |
| `convex` | 任意 | 物體：凸多邊形 |
| `polygon` | 任意 | 物體：一般多邊形（可以是凹的） |
| `mesh` | 任意 | 物體：從 `.obj` 讀進來的模型 |
| `light` | 至少 1 | 光源（球形） |

材質和介面要**先定義、後使用**。

---

## 5. 各指令說明

### `resolution <寬> <高>`

```
resolution 720 480
```

輸出影像的像素數。可以被命令列的 `--width`、`--height` 覆蓋（見第 10 節）。

### `camera <startX> <endX> <startY> <endY> <z> <depth>`

```
camera 144 576 172.8 460.8 -160 720
```

針孔相機，對應 `newRegularCamera`：

- **感光面**是平面 `z` 上的矩形 `[startX, endX] × [startY, endY]`。
- **觀察點**在感光面中心的正前方 `depth` 處：`((startX+endX)/2, (startY+endY)/2, z+depth)`。
- 像素 `(0, 0)` 對應感光面的**左下角**（`startX, startY`），像素 `(寬, 高)` 對應右上角。
- 每條光線從觀察點出發，穿過感光面上對應的點，射向場景。

感光面矩形的長寬比應該和解析度一致，否則畫面會被拉伸。

### `material <名稱> <預設材質> [concentration=<c>]`

```
material air    air
material white  whitePlastic
material sapph  sapphire concentration=5e-3
```

只能用內建的預設材質（見第 6 節）。`concentration` **只有 `sapphire` 能用，而且必填**：鐵、鈦離子的莫耳濃度，建議 `1e-3` 到 `1e-2`，越高越藍。

### `interface <名稱> <內側材質> <外側材質> roughness=<r>`

```
interface gemI    gem   air roughness=0
interface groundI white air roughness=1
```

- 內側、外側材質要先用 `material` 定義。
- `roughness` **必填**，範圍 0 到 1，越大越粗糙。程式內部用 `alpha = roughness²`（GGX 微表面模型）。
- `roughness=0` 是完美光滑：鏡面反射、完美折射。內側是透明、散射或金屬材質時，這種表面不做 NEE（直接對光源取樣）。

### `sphere <介面> <cx> <cy> <cz> <半徑>`

```
sphere marbleI 180 240 -336 72
```

法線朝外，所以球的**內部**用介面的 `inside` 材質。

### `triangle <介面> <x1 y1 z1> <x2 y2 z2> <x3 y3 z3>`

```
triangle someI  0 0 0   10 0 0   0 10 0
```

逆時針的一面是正面（法線方向）。

### `convex <介面> <點1> <點2> <點3> ...`

```
convex groundI  1440 160 240   1440 160 -480   -720 160 -480   -720 160 240
```

- 至少 3 個點，所有點要在同一平面上。
- **必須是凸多邊形**。程式用「點在每條邊的左側」判斷，凹多邊形會算錯，凹的請用 `polygon`。

### `polygon <介面> <點1> <點2> <點3> ...`

和 `convex` 一樣，但可以是凹多邊形（用奇偶規則判斷點是否在內部）。比 `convex` 慢，凸的請用 `convex`。

### `mesh <介面> <obj 路徑> [scale=<s>] [rotate=<rx>,<ry>,<rz>] [at=<x>,<y>,<z>]`

```
mesh gemI src/static/diamond.obj scale=72 rotate=60,0,0 at=360,240,-336
```

- 讀取 `.obj` 檔，每個頂點依序做**縮放 → 繞 X 軸轉 → 繞 Y 軸轉 → 繞 Z 軸轉 → 平移**（`regularTransform`，**順序固定**）。角度單位是度。
- 預設值：`scale=1`、`rotate=0,0,0`、`at=0,0,0`。
- 每個面依頂點數變成三角形（3 個頂點）或一般多邊形（4 個以上），再組成一個群組。
- 整個模型用**同一個介面**。

**`.obj` 支援範圍：** 只讀 `v`（頂點）和 `f`（面）兩種行，其他行（`vn`、`vt`、`o`、`g`、`usemtl` …）都忽略。面的索引可以寫成 `1`、`1/2`、`1//3` 或 `1/2/3`，只使用第一個數字（頂點編號）。

### `light <cx> <cy> <cz> <半徑> blackbody=<T> [scale=<k>]`

```
light 0 480 -192 72 blackbody=2800
light 360 240 -462 18 blackbody=5500 scale=2
```

- **光源只能是球**，因為只有球有實作表面取樣和機率密度（NEE、MIS 需要）。
- 光源不是物體：光線打到它就取得它的光，不會反射或折射。
- 光譜見第 7 節。

---

## 6. 預設材質

| 名稱 | 類別 | 說明 |
|---|---|---|
| `air` | 透明 | 折射率 1，不吸收 |
| `glass` | 透明 | 折射率和吸收來自 `glass_n.csv`、`glass_k.csv` |
| `diamond` | 透明 | 折射率約 2.4，有色散 |
| `sapphire` | 透明 | 需要 `concentration`，濃度決定藍色深淺 |
| `whitePlastic` | 不透明 | 折射率 1.5，底色反射率 0.8（白），表面漫射 |
| `gold` | 金屬 | 複數折射率來自 `au_n.csv`、`au_k.csv` |
| `silver` | 金屬 | `ag_*.csv` |
| `copper` | 金屬 | `cu_*.csv` |
| `iron` | 金屬 | `fe_*.csv` |
| `marble` | 散射 | 米氏散射（Henyey-Greenstein，g = 0.9），白色 |
| `pinkMarble` | 散射 | 同上，吸收隨波長變化，呈粉紅色 |
| `aerogel` | 散射 | 瑞立散射（散射 ∝ 1/λ⁴），淡藍色 |

**類別的意義：**

- **透明**：光可以折射進去，在裡面依 Beer 定律吸收。
- **不透明**：一部分鏡面反射，其餘漫射，光不會進入內部。
- **金屬**：只反射，不折射也不漫射。
- **散射**：光進入內部後做隨機走動（次表面散射），最後從某處出來。

金屬和散射材質要放在介面的 `inside`，`outside` 通常是 `air`。

---

## 7. 光源光譜

```
I(λ) = scale × B(λ, T) / B(555 nm, T)
```

`B(λ, T)` 是普朗克黑體輻射。除以 555 nm 的值，讓所有溫度的光在 555 nm 的強度都是 `scale`（預設 1）。

原本程式裡的光源都是這個形式：

| 原本的函式 | 等於 |
|---|---|
| `tungstenLampBase` | `blackbody=2800` |
| `sunlightBase` | `blackbody=5500` |
| `whiteLightBase` | `blackbody=6500` |
| `example.c` 的 `coldLightBase` | `blackbody=9500` |

已驗證：程式裡寫死的除數和 `B(555 nm, T)` 算出來的值**完全相同**，所以用 `blackbody=` 可以逐位元重現原本的場景。

---

## 8. 順序的意義

**物體和光源的先後順序會影響結果**，檔案裡的順序就是建立的順序：

- 一條光線同時打到兩個距離相同的物體時，取**後面**的那個。
- NEE 用光源的編號隨機選燈，光源的順序不同，用到的亂數就不同。

所以要逐位元重現某個場景，物體和光源的順序都要一樣。只是做新場景的話，順序不重要。

---

## 9. 錯誤處理

任何錯誤都會印出**檔名和行號**，然後結束（不渲染）。例如：

```
scenes/test.txt:12: unknown interface 'gemI2'
scenes/test.txt:20: 'convex' needs at least 3 points, got 2
scenes/test.txt:31: unknown option 'rotation' for 'mesh' (did you mean 'rotate'?)
```

會被當成錯誤的情況：

- 第一個有效行不是 `pathtracer-scene 1`
- 未知的指令或選用參數（避免打錯字卻沒發現）
- 參數個數不對、數字格式錯誤
- 使用未定義的材質或介面；同名的材質或介面重複定義
- `resolution` 或 `camera` 缺少或重複
- 沒有任何 `light`（程式在沒有光源時會除以零）
- `sapphire` 沒有 `concentration`，或其他材質寫了 `concentration`
- `roughness` 不在 0 到 1 之間；半徑、`scale` 不是正數；解析度不是正整數
- `.obj` 檔打不開，或面引用了不存在的頂點

---

## 10. 命令列

| 選項 | 說明 |
|---|---|
| `--scene <檔案>` | 讀取場景檔。沒有指定時使用 `example.c` 寫死的場景 |
| `--width <寬>`、`--height <高>` | 覆蓋場景檔的 `resolution`。長寬比和相機的感光面不同時會印警告，因為畫面會被拉伸 |

其他 benchmark 選項（`--bench`、`--spp`、`--threads`、`--seed`、`--out`、`--out-xyz`）不變，見 `BENCHMARK.md`。

**不放進場景檔的設定：** `maxDepth`（每條路徑最多 bounce 數）維持寫死的 32。它是 benchmark 工作量的一部分，所有場景都一樣。

---

## 11. 限制

| 不支援 | 原因 |
|---|---|
| 自訂材質（自己給折射率曲線、散射係數） | 材質需要 C 函式；v1 只支援內建材質 |
| 黑體以外的光譜 | 同上 |
| 非球形的光源 | 只有球實作了表面取樣和機率密度 |
| 其他種類的相機 | 只有針孔相機 |
| 物體的階層結構、場景引用其他場景檔 | v1 先求簡單 |

這些以後需要時可以擴充，第一行的版本號就是為此保留的。

---

## 12. 完整範例：`example.c` 的場景

這是 `example.c` 的場景改寫成場景檔的樣子。

```
pathtracer-scene 1

resolution 720 480
camera 144 576 172.8 460.8 -160 720

material air      air
material white    whitePlastic
material pink     pinkMarble
material gem      diamond
material sapph    sapphire concentration=5e-3
material gold     gold
material glass    glass
material aerogel  aerogel

interface groundI   white   air roughness=1
interface marbleI   pink    air roughness=0
interface diamondI  gem     air roughness=0
interface sapphI    sapph   air roughness=0
interface glassI    glass   air roughness=0.5
interface aerogelI  aerogel air roughness=1
interface goldI     gold    air roughness=0.3

# 物體（順序和 example.c 相同）
convex  groundI   1440 160 240   1440 160 -480   -720 160 -480   -720 160 240   # 地板
convex  groundI   1440 160 -480  1440 720 -480   -720 720 -480   -720 160 -480  # 背牆
sphere  marbleI   180 240 -336  72
mesh    diamondI  src/static/diamond.obj scale=72   rotate=60,0,0   at=360,240,-336
mesh    sapphI    src/static/gem.obj     scale=72   rotate=60,0,0   at=540,240,-336
mesh    glassI    src/static/cube.obj    scale=46.8 rotate=45,45,45 at=540,405.6,-336
mesh    aerogelI  src/static/cube.obj    scale=54                   at=180,405.6,-336
mesh    goldI     src/static/apple.obj   scale=360                  at=360,405.6,-336

# 光源（順序和 example.c 相同）
light   0   480 -192  72   blackbody=2800   # 鎢絲燈
light   360 240 -462  18   blackbody=5500   # 陽光
light   720 480 -192  72   blackbody=9500   # 冷光
light   0   480 0     180  blackbody=5500   # 陽光（大）
```

**關於精確度：** `example.c` 的座標是算式，例如相機的 `height * 0.36`，算出來是 `172.79999999999998` 而不是 `172.8`；玻璃方塊的 `radius * 0.65` 是 `46.800000000000004`。上面為了好讀寫成 `172.8`，實際的 `scenes/example.txt` 則用 17 位有效數字寫出精確值，所以能和寫死的場景**逐位元相同**（已用 `cmp` 驗證，20 和 7 條執行緒都相同）。

---

## 13. 實作進度

- [x] `src/scene.c`、`src/scene.h`：解析器，建立 `Object **`、`LightSource **`、`Camera *`，`destroyScene` 負責釋放。
- [x] `example.c`：加上 `--scene`、`--width`、`--height`。
- [x] `scenes/example.txt`：和寫死的場景逐位元相同，用 `cmp` 驗證。
- [ ] 另外 3 個測試場景：純漫射、大量幾何、重散射。
