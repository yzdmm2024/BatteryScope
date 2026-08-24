# 电量透视 · BatteryScope

一个为 **TrollStore** 打造的 iOS 电量分析 App。把苹果「设置 → 电池」里那坨又丑又看不清的数据，重新做成一个**轻量玻璃拟态**的 24 小时纵向时间轴：每分钟整机的真实掉电亮度、每小时每个 App 的真实耗电、以及「后台耗电大户」高亮。

> 设计风格：柔和低饱和渐变背景 · 半透明白色 + 背景模糊卡片 · 大圆角 · 微弱外阴影悬浮 · 控件圆润 · 按压缩放 · 无描边 · 无厚重立体阴影。

---

## ⚠️ 先说清楚两件事（很重要）

### 1. 你这台机器的 TrollStore 能装，但要多一步
iPhone 12 Pro = A14（arm64e），iOS 16.6.1。这个版本**有 CoreTrust 漏洞但没有现成安装向量**（KFD 只在 16.6.1 Beta1 可用）。
不能直接装，请用以下任一方式：
- **TrollStar**（iOS 16 – 16.6.1 专用，基于 kfund）
- **TrollInstallerX**（16.5.1 – 16.6.1 arm64e 走「间接安装」）

装好 TrollStore 后，把本项目的 IPA 用 TrollStore 打开安装即可。

### 2. iOS 不记录「每分钟每个 App 耗电」
这是硬性事实，不是偷懒：
- 苹果系统**只按「每小时 / 24 小时 / 10 天」聚合**每个 App 的耗电，**没有每分钟 × 每 App 的原始记录**。
- 没有越狱，第三方 App **无法实时偷看别的 App 在不在前台**。

所以本 App 的数据策略是：
- ✅ **真实数据**：用 TrollStore 的「无沙盒」权限，直接读系统自己的电池数据库（和「设置→电池」同一份），拿到**真实的每 App × 每小时耗电 + 前台/后台拆分**。
- ✅ **真实每分钟精度**：系统有「整机每 ~20 秒一条」的电量采样表，读出来做成**真实的整机每分钟掉电曲线**，填进时间轴里（每分钟格子的亮度 = 那一刻掉电速度）。
- ⚠️ 把两者拼起来：时间轴里「每分钟」= 整机真实掉电，「App 列表」= 真实每 App 每小时耗电。App 维度的最细粒度就是「每小时」——这是 iOS 的上限，不是本 App 的限制。

如果系统数据库读不到（权限没给到 / 机型路径不同），App 会自动降级为「设备级电量曲线」并在卡片里如实说明，同时提供「数据库探测明细」，方便适配你的机型。

---

## 如何拿到 IPA（你没 Mac，用云端编译）

本项目已配好 GitHub Actions，**不需要 Mac**：

1. 把这个仓库 **Fork** 到你的 GitHub 账号（或导入）。
2. 进入仓库 `Actions` → `Build IPA` → `Run workflow`。
3. 跑完后在 `Artifacts` 里下载 `BatteryScope.ipa`。
4. 用 **TrollStore** 打开安装。

> 本地有 Mac 也行：装 `brew install xcodegen`，然后 `xcodegen generate && xcodebuild -project BatteryScope.xcodeproj -scheme BatteryScope -configuration Release`。

---

## 项目结构

```
BatteryScope/
├─ project.yml                 # xcodegen 工程描述（免手写 pbxproj）
├─ .github/workflows/build.yml # 自动出 IPA
└─ BatteryScope/
   ├─ Info.plist
   ├─ BatteryScope.entitlements  # 无沙盒权限（TrollStore 关键）
   ├─ BatteryScopeApp.swift      # 入口
   ├─ Models.swift               # 数据模型
   ├─ DataLayer.swift            # SQLite 读取 + 系统电池库探测 + 降级
   └─ Views.swift                # 玻璃拟态 UI
```

## 排查：如果看不到「每 App 耗电」
打开 App，滑到底部「数据库探测明细」，把里面的内容截图发我。不同 iOS 小版本电池库的表名/列名会有差异，我会据此在 `DataLayer.swift` 里加适配。

---

## 法律 / 安全提示
本 App 仅读取本机电池统计数据库用于本地可视化，不上传任何数据。TrollStore 利用 CoreTrust 漏洞永久签名，属于「越狱替代」方案，请自行评估风险。
