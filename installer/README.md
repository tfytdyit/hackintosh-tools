# 安装包（分开打）

现在 SensorBar 和 VideoBar 各自一个 `.pkg`，不再打合集包：

```bash
# 在仓库根目录执行
bash installer/make-pkg.sh sensorbar    # → SensorBar-<版本>.pkg
bash installer/make-pkg.sh videobar     # → VideoBar-<版本>.pkg
```

脚本会先跑对应的 `build.sh`，再从 `Info.plist` 读版本号、组装 `/Applications/<App>.app`，
用 `pkgbuild` + `productbuild` 出包；`welcome.html` / `conclusion.html` / `distribution.xml`
里的 `@APP@`、`@VER@`、`@BID@`、`@TITLE@`、`@DESC@` 会被替换。

- 安装位置：`/Applications`
- 本地 ad-hoc 签名，安装时可能提示「无法验证开发者」→ 右键 →「打开」
- 上架 App Store 需要的签名与工程配置见 `mas/README.md`

## 便携版 zip（免 pkg、绕过 Gatekeeper）

```bash
bash installer/make-portable.sh sensors/SensorBar.app
bash installer/make-portable.sh videobar/VideoBar.app   # 或 /Applications/VideoBar.app
```

产出 `SensorBar-<ver>-portable.zip`：里面是 App + `install.command`（双击 → 输一次密码 → 复制到 /Applications、修 owner、注册、打开）。
适合 pkg 被系统拦下时用。
