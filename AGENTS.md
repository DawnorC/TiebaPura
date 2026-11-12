# TiebaPura 开发与验证

## 设备与部署

- 默认在现有 Mate 80 Pro 模拟器上执行编译、覆盖安装、启动和 UI 验证。模拟器未运行时启动现有实例。仅在当前任务明确需要真机验证时使用 HUAWEI Mate 80 Pro 实体设备。
- 部署前用 `devecocli device list --format json` 确认目标是 Mate 80 Pro 模拟器，并用当前 DevEco Studio SDK 的 `hdc list targets -v` 核对连接。后续命令显式指定核对过的设备序列号。
- 默认执行 `devecocli build --modules entry --product default --build-mode debug`，编译成功后执行 `devecocli run --module entry --device <模拟器序列号> --product default --build-mode debug --skip-build`，使用保留数据的覆盖安装。遇到安装或签名错误，报告实际原因。
- 保留现有应用数据和签名。禁止自动卸载、清除应用数据、重置、删除或重建模拟器，也禁止自动更换签名。

## 登录状态与 UI 验证

- 保留现有登录 Session。修改代码时保持与当前开发任务无关的登录和 Session 管理逻辑。出现登录失效时先区分应用恢复、网络请求和服务端会话问题。手动登录由用户完成。
- 禁止读取、打印或上传登录凭据、Cookie、Token 等敏感信息。以界面上的登录状态及个人资料是否加载验证 Session，保存或分享截图和日志时避开敏感内容。
- 覆盖部署后，在模拟器上实际操作受影响的界面。按任务需要用 `devecocli ui window list`、`devecocli ui layout` 和 `devecocli ui screenshot` 核对前台窗口、节点位置和页面变化。明确报告已验证结果、失败原因和模拟器无法复现或支持的功能。
