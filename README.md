# Aegisub-Scripts

> 一些为了方便做屏幕字而制作的小工具

| 脚本文件名 | 工具名称 | 简介 |
| --- | --- | --- |
| `HCoo.DeleteOutOfBounds.lua` | 删除画外字幕 | 遍历选中的行，删除绝对坐标（`\pos` 或 `\move`）超出画面指定距离的行。 |
| `HCoo.FontConverter.lua` | 将中文字体名转换为英文字体名 | 自动扫描并转换字幕中的中文字体名为对应的 `family name`（**需要Python**）。 |
| `HCoo.MoveFromClip.lua` | 根据两点 clip 快速添加 Move | 根据首尾帧的两点矢量 Clip 和当前帧的 Pos，生成 Move。 |
| `HCoo.PatternFill.lua` | 文字内部矢量图案填充 | 使用 Yutils 将文字转换为矢量遮罩，并在文字内部铺设圆点、方块或自定义 ASS 绘图。 |
| `HCoo.RectangleFrame.lua` | 快速添加矩形图框 | 按绝对坐标、文字边界或矩形 clip 快速创建 ASS 矩形图框。 |
| `HCoo.SlantedStripes.lua` | 添加倾斜文字条纹 | 根据所选字幕行中的矩形 clip 生成倾斜条纹文字层。 |
| `HCoo.Typewriter.lua` | 字幕逐字逐音节出现 | 让选中行的字幕按指定的固定时间间隔逐字字显现（打字机效果）。 |
