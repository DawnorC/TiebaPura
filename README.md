# TiebaPura

[![GPL-3.0](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![HarmonyOS 7 / API 26](https://img.shields.io/badge/HarmonyOS%207-API%2026-000000.svg)
![ArkTS / ArkUI](https://img.shields.io/badge/ArkTS-ArkUI-3178C6.svg)

**当前版本 `v1.1.0`** · 2026-11-12

TiebaPura 是用 ArkTS 和 ArkUI 编写的 HarmonyOS 原生贴吧客户端。这里是 [DawnorC 维护的分支](https://github.com/DawnorC/TiebaPura)，源自 [a307608689-afk 的 TiebaPura](https://github.com/a307608689-afk/TiebaPura)。这个分支集中改进吧主页、帖子阅读和界面设置。

## 本分支的改动

| 场景 | v1.1.0 中的变化 |
| --- | --- |
| 吧主页 | 有头图的吧使用头图作为顶部背景，并用头图取色衔接折叠后的顶栏。滚动时小头像和吧名逐渐淡入，松手时结合拖动距离和速度决定展开或吸附。下拉刷新沿用吧头背景。 |
| 吧内浏览 | 下一页提前请求，收到后整批追加卡片。遇到整页重复帖子时继续请求，等待时显示加载或重试。点帖子卡片里的图片可直接预览。吧头会尝试读取服务端签到状态，包括通过其他客户端完成的签到。 |
| 帖子与楼中楼 | 回复列表可以继续加载后续楼层。楼中楼从底部打开，阅读时能看到原帖页面。新增针对具体楼层或楼中楼评论的回复入口，编辑器会显示回复对象。 |
| 界面布局 | 在 **设置 → 界面布局** 切换悬浮或固定顶栏和底栏。可以独立开关悬浮底栏周围的渐变与模糊，并调整页面留白、卡片圆角、最近进入的吧头像大小和顶栏模糊。 |
| 发帖与回复 | 吧页可打开应用内发帖编辑器，帖子页可打开回复编辑器。发送前需要再次确认。 |

## 其他功能

- 推荐和关注动态，关注的吧与最近浏览，全站搜吧、搜贴、搜人，以及吧内搜索。
- 帖子正序、倒序、只看楼主与楼层跳转，图片预览、点赞、分享和收藏。
- 网页登录与登录状态持久化，消息、个人主页、关注、粉丝与黑名单管理。
- 本地收藏分类、搜索和排序，以及云端收藏入口。

## 构建与运行

需要 DevEco Studio、HarmonyOS 7 / API 26 SDK 和 DevEco CLI。用 DevEco Studio 打开仓库根目录，在本机配置调试签名。证书、Profile 和本机签名设置由各开发者自行保管。

默认使用现有 Mate 80 Pro 模拟器。以下命令在仓库根目录运行。

```powershell
devecocli device list --format json
hdc list targets -v
devecocli build --modules entry --product default --build-mode debug
devecocli run --module entry --device "<模拟器序列号>" --product default --build-mode debug --skip-build
```

用前两条命令确认序列号，其中 `hdc` 使用当前 DevEco Studio SDK 自带的版本。更新时保留同一签名，以覆盖安装保留应用数据和登录状态。设备选择、登录保护和 UI 验证的具体约定见 [AGENTS.md](AGENTS.md)。

## 验证状态与反馈

- 吧内分页已在 Mate 80 Pro 模拟器上回归。对 rimworld 吧连续快速上滑 14 次，列表从 13 条增至 33 条，再增至 53 条。
- 发帖和回复目前仅完成代码接入与编译检查，服务端实际发送结果尚未验证。
- 客户端依赖百度贴吧服务。登录、读写接口和风控规则可能变化，功能可用性以实际服务响应为准。

反馈问题时，请附上应用版本、设备或模拟器型号，以及复现步骤。截图或日志请先去掉账号凭据、Cookie 和 Token。[提交 Issue](https://github.com/DawnorC/TiebaPura/issues)

## 源码与文档

| 路径 | 内容 |
| --- | --- |
| [AppScope/](AppScope/) | 应用版本、全局配置与资源 |
| [entry/src/main/ets/pages/](entry/src/main/ets/pages/) | 首页、进吧、帖子、楼中楼及设置页面 |
| [entry/src/main/ets/components/](entry/src/main/ets/components/) | 栏位、卡片及其他公共组件 |
| [entry/src/main/ets/service/](entry/src/main/ets/service/) 与 [network/](entry/src/main/ets/network/) | 业务接口、缓存协调、HTTP 和 Protobuf 编解码 |
| [docs/](docs/) | 帖子预加载、下拉刷新、图片加载及其他维护记录 |

## 许可证与致谢

原项目版权归 a307608689-afk。本分支保留原项目版权声明，按 [GNU GPL v3.0](LICENSE) 发布。感谢 [TiebaLite](https://github.com/min09577/TiebaLite)、[aiotieba](https://github.com/lumina37/aiotieba) 与 [tbclient.protobuf](https://github.com/n0099/tbclient.protobuf) 提供的公开接口与协议参考。

TiebaPura 是第三方开源项目，与百度无隶属或授权关系。贴吧商标、内容与服务归相应权利人所有。请遵守百度贴吧服务条款，使用前可查阅 [隐私政策](docs/PRIVACY.md)。
