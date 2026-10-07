# 壁纸控制接口

### 切换下一张壁纸
- **URL**: `/api/wallpaper/change`
- **Method**: `GET` 或 `POST`
- **说明**: 强制触发壁纸引擎刷新或切换到下一张壁纸。

### 切换上一张壁纸
- **URL**: `/api/wallpaper/previous`
- **Method**: `GET` 或 `POST`
- **说明**: 强制触发壁纸引擎切换回上一张壁纸。

### 保存当前壁纸
- **URL**: `/api/wallpaper/save`
- **Method**: `POST`
- **说明**: 将当前显示的壁纸永久保存到指定的收藏目录。
