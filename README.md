# 一生足迹（LifeFootprints）

极简的足迹回顾 iOS App —— 从相册照片位置 + CSV 导入历史数据，生成属于你的深色足迹地图。

> This is not a map of the city. This is a map of me.

## 目录结构

```
├── LifeFootprints.xcodeproj   # Xcode 工程（Xcode 16+，对象版本 77）
├── LifeFootprints/
│   ├── LifeFootprintsApp.swift    # 入口 + 引导页切换
│   ├── Models/                    # SwiftData 模型 + 主题
│   ├── Services/                  # 相册扫描 / 数据存取 / 统计 / 导出
│   ├── Views/                     # 地图 / 统计 / 设置 / 引导 / CSV 导入
│   ├── CoreLogic/                 # 纯逻辑（无 iOS 依赖，可独立单测）
│   └── Assets.xcassets
├── Tests/main.swift               # 核心逻辑单元测试（macOS 可跑）
└── Package.swift                  # 逻辑测试用的 SwiftPM 包
```

## 运行

1. 安装 **Xcode 16+**（App Store 免费）
2. 双击 `LifeFootprints.xcodeproj` 打开
3. 选择任意 iPhone 模拟器，⌘R 运行
4. 首次启动会请求相册权限 → 扫描照片位置 → 生成足迹地图

## 运行核心逻辑单元测试（无需 Xcode）

```bash
swift build
./.build/debug/FootprintTests
```

## 功能（M1 MVP）

- 相册照片 GPS 位置提取（支持「选中的照片」受限权限）
- CSV 导入（自动识别表头 + 手动列映射 + 预览 + 同日 ±50m 去重）
- 深色足迹地图（MapKit 深色外观 + 按频次高亮足迹线，线/点双模式）
- 时间轴回放（足迹按月份动态出现）
- 五套主题（Crimson / Arctic / Neon / Sunset / Mono）
- 统计（足迹点 / 总里程 / 活跃天 / 年度分布 / 密集区域）
- 导出备份（CSV）、清空数据

## 隐私

所有数据仅保存在本机（SwiftData 本地库），无账号、无上传、无广告。
