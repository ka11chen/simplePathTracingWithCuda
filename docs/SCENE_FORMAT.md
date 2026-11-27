# 場景檔格式 v1

場景檔使用 UTF-8 純文字，描述解析度、相機、材質、物體表面介面、幾何與光源。完整範例見 [scenes/example.txt](../scenes/example.txt)。從專案根目錄執行下列指令即可載入。

```sh
./bin/pathTracing --bench --scene scenes/example.txt
```

執行參數與建置方式見 [效能量測指南](BENCHMARK.md)。

## 檔案結構

第一個有效行必須是 `pathtracer-scene 1`。此後每個資料行以指令名稱開頭，欄位用空白或 Tab 分隔。空行和從 `#` 到行尾的註解會被忽略。

位置參數按表中的順序填寫，選用參數以 `key=value` 放在位置參數之後。座標點寫為 `x y z`，具名向量寫為 `x,y,z`，逗號兩側不留空白。實數支援小數、負數和科學記號。材質與介面名稱使用英數字和底線，區分大小寫，須先定義再引用。相對路徑以專案根目錄為準，路徑中不得含空白。

| 項目 | 次數 | 語法 |
| --- | --- | --- |
| 版本 | 一次，位於第一個有效行 | `pathtracer-scene 1` |
| 解析度 | 一次 | `resolution <width> <height>` |
| 相機 | 一次 | `camera <startX> <endX> <startY> <endY> <z> <depth>` |
| 材質 | 任意 | `material <name> <preset> [concentration=<c>]` |
| 表面介面 | 任意 | `interface <name> <inside> <outside> roughness=<r>` |
| 球形物體 | 任意 | `sphere <interface> <cx> <cy> <cz> <radius>` |
| 三角形 | 任意 | `triangle <interface> <p1> <p2> <p3>` |
| 凸多邊形 | 任意 | `convex <interface> <p1> <p2> <p3> ...` |
| 一般多邊形 | 任意 | `polygon <interface> <p1> <p2> <p3> ...` |
| OBJ 網格 | 任意 | `mesh <interface> <path> [scale=<s>] [rotate=<rx>,<ry>,<rz>] [at=<x>,<y>,<z>]` |
| 球形光源 | 至少一次 | `light <cx> <cy> <cz> <radius> blackbody=<T> [scale=<k>]` |

`<p1>` 等表示各由三個座標值組成的點，方括號表示選用參數。物體與光源以檔案中的出現順序建立。固定種子重現渲染時，應保留兩者各自的順序。

## 座標與相機

場景使用右手座標系，`+X` 向右、`+Y` 向上、`+Z` 朝向觀察者。每個場景座標單位是 0.1 mm。多邊形從正面看時頂點為逆時針，法線指向正面。球的法線朝外。

`resolution` 依序指定影像寬、高（像素），兩者皆為正整數。`camera` 的前四個參數指定成像平面的 X、Y 範圍，第五個參數是平面的 `z`。針孔的 X、Y 座標位於平面中央，Z 座標為 `z + depth`。每軸的起、終值須不同，`depth` 須非零。影像和成像平面應使用相同長寬比。命令列的 `--width` 和 `--height` 可覆蓋影像解析度。

## 材質與表面介面

`material` 用名稱引用內建材質。各預設的名稱區分大小寫。

| 類型 | 預設材質 |
| --- | --- |
| 透明 | `air`、`glass`、`diamond`、`sapphire` |
| 不透明 | `whitePlastic` |
| 金屬 | `gold`、`silver`、`copper`、`iron` |
| 次表面散射 | `marble`、`pinkMarble`、`aerogel` |

`sapphire` 須指定 `concentration`，例如 `material gem sapphire concentration=5e-3`。濃度會影響藍色深淺。

`interface` 依序引用內側與外側的材質名稱，再指定 `roughness`。法線指向外側，另一面是內側。粗糙度範圍為 0 至 1，0 代表光滑表面。物體以介面名稱引用這組設定，多個物體可共用同一個介面。

## 幾何與光源

- `sphere` 指定球心和正半徑。`triangle` 指定三個頂點。`convex` 和 `polygon` 至少指定三個共面頂點，凹多邊形使用 `polygon`。
- `mesh` 以 OBJ 的 `v` 和 `f` 資料建立網格，整個網格使用同一個介面。頂點依序等比縮放、以度數繞 X、Y、Z 軸旋轉，最後平移。`scale` 預設為 1，`rotate` 與 `at` 預設為 `0,0,0`。
- `light` 指定球心、正半徑和黑體色溫 `blackbody`（K）。色溫與 `scale` 均為正數。光譜在 555 nm 的強度為 `scale`，預設為 1。例如 `blackbody=2800` 是鎢絲燈，`blackbody=5500` 是日光。
