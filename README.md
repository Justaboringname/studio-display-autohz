# studio-display-autohz

_Last updated: 2026-06-11_

让被 SwitchResX 超频到 86.5Hz 的 Studio Display(5K)在每次插入 / 开机 / 唤醒时自动回到最高刷新率,不再需要手动打开 SwitchResX 切换。并且**感知游戏**:Riot Client / League of Legends 任一在运行时自动切 4K 120Hz(HiDPI),全部退出后自动切回 5K 86.5Hz。

## 用法

```sh
make            # 编译
make install    # 安装到 ~/.local/bin + 装载 LaunchAgent(开机自启)
make uninstall  # 卸载

studio-display-autohz status   # 看当前/目标模式
studio-display-autohz enforce  # 手动一次性切换
```

日志:`~/Library/Logs/studio-display-autohz.log`

工作方式:LaunchAgent 常驻一个 watcher,在 ① 启动时 ② `CGDisplayReconfigurationCallback` 报告目标显示器(vendor `0x610` / product `0xae42`)接入时 ③ 系统唤醒时 ④ 游戏 app 启动/退出时,按当前期望 profile 选模式,用 `CGConfigureDisplayWithDisplayMode(..., .permanently)` 应用:

- **办公 profile(默认)**:5120×2880 HiDPI、≥80Hz 里刷新最高的(= 86.5)
- **游戏 profile**(`com.riotgames.RiotGames.RiotClient` 或 `com.riotgames.leagueoflegends` 任一在跑):3840×2160 HiDPI、≥100Hz(= 4K120)。把游戏本体也算进触发集合,是防止打到一半客户端退出导致屏幕中途切回 5K。

接入后会在 +2s/+8s/+20s 重试三次,因为 SwitchResX daemon 注入完整模式表略有延迟;游戏退出后在 +1s/+5s/+12s 重查三次,因为 macOS 的 `didTerminateApplicationNotification` 触发时退出中的进程还会在 `runningApplications` 里赖几秒(实测 Riot 残留 1~5s,会导致立即判定误判)。**不依赖、也不调用 SwitchResX**——只要它的 override 还装着(模式在系统模式表里),本工具就能切。

注意:SwitchResX 的**无头 daemon**(`SwitchResX Daemon.app`,LSUIElement,无任何可见 UI)需要保持登录自启,因为 86.5 模式是它在运行时注入模式表的;但菜单栏的 SwitchResX Control 和设置面板永远不用打开。实测 daemon 自己启动时会应用一个它记忆的"默认模式"(曾把屏幕设成 1080p120),本 watcher 会在 ~1s 内纠正。拔掉外接屏时无需任何动作——MacBook Pro 内置屏是 ProMotion 自适应 120Hz,一直处于最高能力状态。

## SwitchResX 在 Apple Silicon 上的超频原理(实地逆向结论,2026-06-11)

在本机(M1 Pro + Studio Display 5K,SwitchResX 4 daemon Version 4140399)上实测得出,分三层:

### 1. root helper:只是"代写文件的手"

`/Library/PrivilegedHelperTools/fr.madrau.switchresx.helper`(SMJobBless 安装,只链 Foundation/Security)负责以 root 身份写两类东西:

- `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-610/DisplayProductID-ae42` —— 经典 display override plist:自定义名字(所以系统里显示 `SwitchResX4 - Studio Display XDR`)、`scale-resolutions`(HiDPI 缩放档列表)、以及**整块替换的 `IODisplayEDID`(896 字节 = 7 个 128 字节块)**。伪造后的 EDID/DisplayID 把显示器声明成 `MaximumRefreshRate=120`、`SupportsVariableRefreshRate=Yes`、`ContinuousFrequencySupport=CVTv1X`(可在 `ioreg -c AppleCLCD2` 的 `DisplayAttributes` 里看到)——这是让 macOS/DCP 愿意接受非标时序的关键。ProductID 也被改成 `0xae42`(非真实 ID),避开系统内建 override(`/System/Library/Displays/.../DisplayVendorID-610/` 里的 ae22/ae2e/ae3a/ae3e)的钳制。
- `DisplayProductID-ae42.mtdd` —— Apple Silicon 特有的 multi-tile display description:5K 屏走 **2 条 DP stream、每 tile 2560×2880**(`linkmode=multi-cable, streamcount=2, tileinfo=(2,1)`),文件里直接写明每条 stream 的 `backendtiming` 和合成后的 `frontendtiming`(`活动像素,front porch,sync,htotal × 活动行,front porch,sync,vtotal @ 像素时钟`),教 DCP(display coprocessor)自定义线缆时序。
- 另外还会改 `/Library/Preferences/com.apple.CoreDisplay` 的 `multiRefreshRateScaledModes` / `appleMultiRefreshRateScaledModes` 开关(helper 里就是直接拼 `defaults write` 命令)。

### 2. 用户态 daemon:运行时注入模式表

`SwitchResX Daemon.app`(prefPane 的 PlugIns 里)链接 **CoreDisplay / SkyLight / MonitorPanel / DisplayServices 私有框架**,用 `CGSConfigureDisplayMode`、`SLSDetectDisplays`、`CoreDisplay_Display_*` 等私有符号在运行时维护/注入模式表。它的活动数据库是 `/Library/Preferences/.fr.madrau.switchresx.daemon.plist`(隐藏、root 属主、~1MB)。

证据:磁盘上的 `.mtdd`(4 月 11 日)只含 60Hz(`5200×3000 @ 936MHz`)和旧的 86.0Hz(`5200×2999 @ 1341.16MHz`)两条时序,但 5 月 30 日创建的 86.5Hz 模式照样生效——活动模式表(隐藏 plist)里 18 条 86Hz 模式**全部**是 `1349410048`(86.5),86.0 的 `1341159936` 一条不剩。即 daemon 在运行时把模式表整个换掉了,不必重写 override 文件。

### 3. 实际生效的 86.5Hz 时序

```
5120×2880 活动区,H: 8/32/40(htotal 5200),V: 106/8/6(vtotal 3000)
像素时钟 1349.41 MHz → 1349410048 / (5200×3000) = 86.5006 Hz
```

验证途径:`ioreg -c AppleCLCD2` 里外接屏的 `DPTimingModeId = 58`,正对应活动模式表中 86.5006Hz 时序的 `elementID = 58`(60Hz 是 element 46)。**注意公开 CG API(`CGDisplayMode.refreshRate`)对这些注入模式只报声明值 "86.0",分不清 86.0/86.5,要看 IOKit。**

### 为什么 87Hz 崩

未严格证实,但数字非常巧:87Hz → 5200×3000×87 = **1357.2 MHz**,而 86.5Hz 的 1349.41 MHz 恰好贴着 ~1.35GHz;M1 Pro 的 DCP 单 head 前端像素时钟上限大约就在这附近(对照:它官方支持的最大外接 6K XDR@60 ≈ 1286 MHz)。即瓶颈大概率是 SoC display engine 的前端像素时钟,不是 DP 链路带宽(2 stream 平摊后每条 ~675MHz,HBR3 下余量很大)。

## 设计取舍

- 只在「接入 / 启动 / 唤醒」时 enforce,**不在模式变化时 enforce**——避免和手动切换(比如临时想试别的刷新率)打架。
- 用 `ioDisplayModeID` 比较当前/目标,避免 86.0/86.5 声明值相同导致误判"已达标"。
- 若 SwitchResX override 未加载(找不到 ≥80Hz 模式),只记日志不动作。
