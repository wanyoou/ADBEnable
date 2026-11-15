# ADB Enable — Magisk 模块

给**屏幕损坏 / 触摸失灵 / 刚解锁 BL 清空数据**的手机用的救机模块：开机自动把 ADB 打通，
默认免授权（不需要公钥），修复 USB 枚举与 `adbd`，顺带绕过 MIUI / HyperOS 的安全设置限制，
让 `scrcpy` 能直接投屏并用电脑鼠标键盘操作手机。

- 模块 ID：`adb_enable`
- 模块名：`ADB Enable`
- 版本：`v1.0.0`（versionCode `10000`）
- 状态目录：`/data/adb/adb-enable/`
- 日志：`/data/adb/adb-enable/log/adb-enable.log`

> **⚠️ 安全警告**
>
> 刷入本模块并保持默认配置后，**任何能物理接触到手机、插上数据线的人，都可以直接拿到
> 这台手机的 `adb shell`**，不需要在手机上点“允许”，也不需要输入锁屏密码。
> 这是“坏屏零配置”换来的代价，不是 bug。
> 风险细节、适用场景和加固方法见[第七节](#security)。

---

## 目录

1. [最小使用流程](#minimal)
2. [它解决的问题](#problem)
3. [功能一览](#features)
4. [安装细节](#install)
5. [配置](#config)
6. [公钥（可选）](#keys)
7. [安全与风险](#security)
8. [命令行工具](#cli)
9. [工作原理](#how)
10. [排错](#troubleshoot)
11. [卸载](#uninstall)
12. [开发 / 构建 / 测试](#dev)
13. [致谢](#thanks)

<a id="minimal"></a>
## 一、最小使用流程

前提：手机已解锁 Bootloader 并装有 Magisk；能用 TWRP，或者当前 ADB 还能用。

### 方式 1：TWRP（坏屏推荐）

```powershell
# 1) 把 zip 推到手机
adb push .\ADB-Enable-v1.0.0.zip /sdcard/

# 2) 在 TWRP 里安装（不需要触摸）
adb shell "twrp install /sdcard/ADB-Enable-v1.0.0.zip"

# 3) 重启
adb reboot
```

### 方式 2：ADB 已经可用

```powershell
adb push .\ADB-Enable-v1.0.0.zip /sdcard/
adb shell "su -c 'magisk --install-module /sdcard/ADB-Enable-v1.0.0.zip'"
adb reboot
```

重启后等半分钟到一分钟（模块默认在开机完成后再等 8 秒），然后：

```powershell
adb devices
# 740fc4ec        device

scrcpy
```

**不需要准备、推送或放置任何公钥。** 模块会在 `adbd` 启动前设好
`ro.adb.secure=0`，在已解锁 Bootloader 的设备上直接跳过授权握手（原理见[第六节](#keys)）。

- 如果显示 `unauthorized`：说明你的 ROM 不认这个属性，或你关闭了免授权模式，请看[第六节](#keys)。
- 如果 `adb devices` 完全空白：先看[第十节](#troubleshoot)的排错表。
- 如果手机有密码锁屏：可以直接在 scrcpy 窗口里用电脑键盘输入 PIN。

> ⚠️ 默认模式下，任何能插线的人都能拿到 `adb shell`。修好屏幕后请按
> [第七节](#security)加固，或直接[卸载](#uninstall)。

<a id="problem"></a>
## 二、它解决的问题

典型症状：

1. 只写了 `system.prop` 属性，重启后 `adb devices` 仍然空白；
2. 尝试用脚本执行 `settings put global adb_enabled 1`，日志却报
   `cmd: Failure calling service settings: Failed transaction (2147483646)`，`adbd` 始终 `stopped`；
3. 刚解锁 BL、数据被清空，手机停在开机向导，屏幕又点不了；
4. 即使连上了，MIUI 也拦着不让 `scrcpy` 模拟点击（`INJECT_EVENTS`）。

根因有六层，缺一层都不通：

| 层 | 问题 | 本模块的处理 |
| --- | --- | --- |
| 系统开关 | Android 10+ 由 `AdbService` 接管 `adbd`，设置库里 `adb_enabled=0` 时系统会主动停掉 `adbd`，只改 `system.prop` 没用 | 用 `settings put global adb_enabled 1` 真正打开开关，并在开机后 90 秒内反复校验 |
| SELinux | `settings put ... >> /data/adb/xxx.log` 会把日志文件 fd 通过 Binder 传给 `system_server`，而 `system_server` 无权写 `/data/adb`，命令直接失败 | 所有 binder 命令的输出都先接到**匿名管道**再写日志（`bcmd()`），绝不把文件 fd 交出去 |
| 授权 | 坏屏无法点“允许 USB 调试”，一连接就 `unauthorized` | 开机早期设 `ro.adb.secure=0`，`adbd` 直接跳过授权；公钥预置作为可选兜底 |
| USB 枚举 | `adbd` 已启动但 USB 功能里没有 `adb`，或 `ffs` 未就绪，电脑看不到设备 | 先用 `svc usb setFunctions`（Android 11+ 框架接口），失败再走 `sys.usb.config none → mtp,adb → adb` 的经典重枚举，并补 `ctl.start adbd` |
| MIUI | “USB 调试（安全设置）”需要小米账号 + SIM 卡，未开时 scrcpy 只能看不能点 | 直接写 `persist.security.adbinput=1`、`persist.security.adbinstall=1` |
| 开机向导 | 清数据后停在 Setup Wizard，没有触摸就卡死 | 在系统启动早期把 `device_provisioned` / `user_setup_complete` 置 1，跳过向导 |

<a id="features"></a>
## 三、功能一览

- 开机自动开启“开发者选项”和“USB 调试”，并持续校验不被系统改回。
- 默认免授权：`ro.adb.secure=0`，不需要公钥、不会弹授权框。
- 可选：自动合并并安装 ADB 公钥（支持多台电脑，已有公钥永远保留），用于关闭免授权模式或个别 ROM。
- 自动修复 USB gadget 枚举 + 启动 `adbd`。
- MIUI / HyperOS 安全设置绕过（`scrcpy` 可点击、可 `adb install`）。
- 可选（默认关闭）：跳过开机向导、点亮屏幕、解锁无密码锁屏、无线 ADB（`5555`）。
- 完整中文日志，失败时会明确写出哪个环节没成功。
- 自带命令行工具 `adb-enable`（`status` / `run` / `addkey` / `wireless` / `config` / `log`）。
- 无 `system/` 覆盖，不挂载任何分区，风险面小。

<a id="install"></a>
## 四、安装细节

三条安装路径的取舍：

| 方式 | 适用场景 | 说明 |
| --- | --- | --- |
| TWRP | 屏幕坏、ADB 也不可用 | 用 `twrp install`，命令行完成，不需要触摸 |
| Magisk 命令行 | 当前 ADB 还能用 | `magisk --install-module`，无需重启进 recovery |
| Magisk App | 触摸还能用 | 模块 → 从本地安装 → 选择 zip |

命令见[第一节](#minimal)。这里只列容易踩的细节：

- **TWRP 里看不到 `/sdcard`**：说明 data 还没解密，先执行
  `adb shell twrp decrypt '你的锁屏密码'`；模块 zip 也可放在 `/data/local/tmp` 再安装。
- **不需要公钥**：默认免授权模式可以直接连。只有在关闭免授权、或 ROM 不认
  `ro.adb.secure` 时才需要，见[第六节](#keys)。
- **首次开机**：模块在 `sys.boot_completed` 后还会等 `BOOT_DELAY`（默认 8 秒）再操作，
  期间 USB 可能重连一两次，等一分钟再试。
- **安装后验证**：`/data/adb/modules/adb_enable/` 存在且没有 `disable` 文件；
  日志在 `/data/adb/adb-enable/log/adb-enable.log`。
- **Magisk 已被 OTA/刷机覆盖**：模块脚本不会运行，先确保 Magisk 本身正常。

<a id="config"></a>
## 五、配置

首次开机自动生成：`/data/adb/adb-enable/config`（0600）。改完执行
`adb-enable run` 可立即生效，或直接重启。

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `ENABLE_ADB` | `1` | 总开关 |
| `FORCE_INSECURE_ADB` | `1` | `ro.adb.secure=0`，`adbd` 完全跳过授权（无需公钥；**降低安全性**，见[第七节](#security)） |
| `USB_CONFIG` | `mtp,adb` | USB 功能组合；只想要 adb 可改成 `adb` |
| `USB_CONFIG_ADB_ONLY` | `adb` | 上面失败时的降级值 |
| `FORCE_USB_REENUM` | `1` | `adb` 功能不活跃时重新枚举 USB |
| `START_ADBD` | `1` | `adbd` 没起来时执行 `ctl.start adbd` |
| `SKIP_SETUP_WIZARD` | `1` | 置 `device_provisioned` / `user_setup_complete`（persist 设置，还原见[第十一节](#uninstall)） |
| `PROVISION_EARLY` | `1` | 在 `sys.boot_completed` 之前写 provisioned，赶在向导之前；设 `0` 则只在开机完成后写 |
| `DISABLE_SETUP_WIZARD_PACKAGES` | `0` | 额外 `pm disable-user` 掉 Setup Wizard |
| `MIUI_SECURITY_BYPASS` | `1` | 写 `persist.security.adbinput` / `adbinstall` |
| `MIUI_FASTBOOT_BYPASS` | `0` | 写 `persist.fastboot.enable`（有刷机风险） |
| `FORCE_DEBUGGABLE` | `0` | `ro.debuggable=1`（可 `adb root`，风险更高） |
| `WIRELESS_ADB` / `WIRELESS_PORT` | `0` / `5555` | **默认关闭**；关闭时在 `post-fs-data`（adbd 启动前）删除 `service`/`persist` 端口属性，运行时关闭还会重启 adbd |
| `WAKE_SCREEN` | `1` | 开机 `KEYCODE_WAKEUP`，scrcpy 才有画面 |
| `STAY_AWAKE` | `0` | `stay_on_while_plugged_in=7` |
| `DISMISS_KEYGUARD` | `1` | `wm dismiss-keyguard`（仅无密码锁屏有效） |
| `BOOT_DELAY` | `8` | 开机完成后等待秒数 |
| `BOOT_WAIT_SECONDS` | `240` | 等待 `sys.boot_completed` 的上限 |
| `RECHECK_SECONDS` / `RECHECK_INTERVAL` | `90` / `15` | 开机后重复校验 `adb_enabled` 的时长/间隔 |
| `SETTINGS_RETRIES` / `SETTINGS_RETRY_DELAY` | `4` / `2` | `settings` 失败重试 |
| `KEYS_KEEP_EXISTING` | `1` | 保留设备已有信任公钥 |
| `KEYS_FROM_STORAGE` | `0` | 设为 `1` 才读取 `/sdcard` 下的公钥；共享存储任意应用可写，开启等于允许它们加入受信任公钥 |
| `KEYS_BACKUP` | `1` | 改动前备份 `adb_keys.bak`；备份失败则不覆盖原文件 |
| `LOG_MAX_BYTES` | `262144` | 单个日志文件上限，超过后轮转 |

公钥相关的选项和放置方式见[第六节](#keys)。

配置文件按纯 `KEY=VALUE` 解析，**不会作为 shell 脚本执行**；未知键会被忽略并写日志。
非法 `USB_CONFIG` 会自动回退到 `mtp,adb`。

<a id="keys"></a>
## 六、公钥（可选）

### 6.1 什么时候需要公钥

默认不需要。只有下面几种情况才需要：

- 你把 `FORCE_INSECURE_ADB` 改成 `0`，想恢复“只信任已授权电脑”的正常授权模型；
- 个别 ROM 的 `adbd` 不认 `ro.adb.secure`，连接一直显示 `unauthorized`；
- Bootloader 重新上锁（`ro.boot.verifiedbootstate` 不是 `orange`），此时 `adbd` 会强制要求授权；
- 你想给多台电脑分别授权，并在关掉免授权后继续免弹窗。

### 6.2 为什么默认不需要公钥

模块在 `post-fs-data` 阶段（`adbd` 启动之前）把 `ro.adb.secure` 设为 `0`。Android 13 的
`adbd` 在 Bootloader 已解锁（`ro.boot.verifiedbootstate=orange`，Magisk 的前提）时执行：

```cpp
auth_required = GetBoolProperty("ro.adb.secure", false);
```

值为 `0` 时 `auth_required=false`，整个授权握手被跳过——电脑上的 `~/.android/adbkey.pub`
根本不需要出现在手机里。模块还会在开机后重启一次 `adbd`，确保它读到的是新值。

### 6.3 公钥文件从哪来

`adbkey.pub` 是**电脑**第一次运行 `adb` 时自动生成的，不需要手机参与：

| 系统 | 路径 |
| --- | --- |
| Windows | `%USERPROFILE%\.android\adbkey.pub` |
| Linux / macOS | `~/.android/adbkey.pub` |

如果文件不存在，可以显式生成：

```powershell
# Windows
adb keygen "$env:USERPROFILE\.android\adbkey"
```

```bash
# Linux / macOS
adb keygen ~/.android/adbkey
```

生成后同目录会出现 `adbkey.pub`（公钥）和 `adbkey`（私钥，**不要外传**）。
换电脑就是另一对密钥，需要把新电脑的 `adbkey.pub` 再给手机一次。

### 6.4 把公钥放到手机上的几种方式

任选一种，模块会在开机时读取并合并（也可以同时用多种）。

**方式 A：TWRP 里预置（坏屏推荐）**

```powershell
# TWRP 的 adb 已经是 root，可以直接写 /data，模块在 adbd 启动前就能读到
adb shell "mkdir -p /data/adb/adb-enable/keys"
adb push "$env:USERPROFILE\.android\adbkey.pub" /data/adb/adb-enable/keys/pc.pub
```

重启后模块会自动导入。之后再加电脑，重复这一步再重启即可。
TWRP 里也可以直接用 `adb-enable addkey`（方式 B），效果相同。

> 从 `/sdcard/adb-enable/keys/` 自动导入需要显式设 `KEYS_FROM_STORAGE=1`。默认关闭，
> 因为共享存储可被任何有存储权限的应用写入，导入的公钥会成为设备的长期信任项。

**方式 B：系统已经能 adb 时，用命令行工具导入**

```powershell
adb push "$env:USERPROFILE\.android\adbkey.pub" /sdcard/adbkey.pub
adb shell "su -c '/data/adb/modules/adb_enable/bin/adb-enable addkey /sdcard/adbkey.pub'"
```

`addkey` 会把文件复制到 `/data/adb/adb-enable/keys/` 并立即合并到
`/data/misc/adb/adb_keys`。这一步需要 root；坏屏时可以在 TWRP 里执行（TWRP shell 本身就是 root，
不需要 `su`）。

**方式 C：直接推到常用落点**

模块会扫描这些位置，放任意一个即可：

```powershell
# 这个位置默认就会读取，且普通应用无法写入
adb push "$env:USERPROFILE\.android\adbkey.pub" /data/local/tmp/adbkey.pub

# 或（需要 KEYS_FROM_STORAGE=1，见下方安全说明）
adb shell "mkdir -p /sdcard/adb-enable"
adb push "$env:USERPROFILE\.android\adbkey.pub" /sdcard/adb-enable/adb_keys
```

**方式 D：把公钥打进 zip（给多台设备批量刷）**

把 `pc.pub` 放进模块源码的 `module/keys/` 再重新打包（或直接往 zip 的 `keys/` 目录里加文件）。
安装时 `customize.sh` 就会导入，开机后 `post-fs-data` 还会再合并一次。

**方式 E：TWRP 直接写 `adb_keys`（终极兜底）**

不依赖模块逻辑，手工写入并修正权限/SELinux 标签：

```powershell
adb push "$env:USERPROFILE\.android\adbkey.pub" /tmp/pc.pub
adb shell "mkdir -p /data/misc/adb && cat /tmp/pc.pub >> /data/misc/adb/adb_keys && chown 1000:2000 /data/misc/adb/adb_keys && chmod 0640 /data/misc/adb/adb_keys && chcon u:object_r:adb_keys_file:s0 /data/misc/adb/adb_keys"
```

### 6.5 公钥读取顺序与格式

模块会合并以下来源，去重、去注释、过滤非法行：

1. `/data/adb/adb-enable/keys/*`（推荐长期存放）
2. `/data/adb/adb-enable/adb_keys`
3. 模块目录下的 `keys/`
4. `/data/local/tmp/adbkey.pub`、`/data/local/tmp/adb_keys`
5. `/sdcard/adbkey.pub`、`/sdcard/adb_keys`、`/sdcard/adb-enable/adb_keys`、`/sdcard/adb-enable/keys/*`（仅 `KEYS_FROM_STORAGE=1`）
6. 设备已有的 `/data/misc/adb/adb_keys`（默认保留，不会丢）

支持两种格式（`adb` 自己生成的是第一种）：

```
QAAAA...<base64> user@host
ssh-rsa AAAAB3Nza... user@host
```

文件名以 `README` 开头或以点开头的文件会被当作说明文档/隐藏文件跳过。没有有效公钥时，模块**不会**创建空的
`adb_keys`，也不会影响默认的免授权连接；已有公钥则永远保留。

### 6.6 撤销某台电脑的信任

1. 删除它在 `/data/adb/adb-enable/keys/` 下对应的文件（如果曾放进 `/sdcard`，也一并删除）；
2. 用 root/TWRP 编辑 `/data/misc/adb/adb_keys`，删掉那一行（`KEYS_KEEP_EXISTING=1` 会保留
   已有行，所以只删来源文件不会自动撤销）；
3. 重启，或执行 `adb-enable run` 让模块重新合并。

<a id="security"></a>
## 七、安全与风险

**刷入本模块并保持默认配置（`FORCE_INSECURE_ADB=1`）后，任何能物理接触到手机、
插上数据线的人，都可以直接拿到这台手机的 `adb shell`，不需要在手机上确认，也不需要密码。**

`adb shell` 以 `shell` 用户运行（默认不是 root），但已经足够做很多事：

- 读取、写入、删除 `/sdcard` 里的照片、下载、文档（设备首次解锁后）；
- 安装/卸载应用、读取已安装应用列表、截屏、录屏；
- 投屏并模拟点击/按键（scrcpy 的完整控制）；
- 修改部分系统设置、触发重启、抓取日志。

如果同时打开 `FORCE_DEBUGGABLE=1`，还可以 `adb root`，风险再高一级（默认关闭）。
另外，**锁屏密码不会阻止 adb 连接**：设备首次解锁后，`adb shell` 仍然可以访问外部存储等数据。

| 风险项 | 默认 | 说明 / 缓解 |
| --- | --- | --- |
| 免授权 `adb shell` | 开 | 任何能插线的人可用；修好屏幕后设为 `FORCE_INSECURE_ADB=0` 并配置公钥 |
| 无线 ADB | 关 | 默认关闭；`post-fs-data` 就删除 5555 相关属性，只有显式设 `WIRELESS_ADB=1` 才监听。打开后同一局域网内的人可连 `5555`，不要在公共网络使用 |
| 共享存储公钥导入 | 关 | 开启 `KEYS_FROM_STORAGE` 后，任何能写 `/sdcard` 的应用都可能加入一个长期受信任的公钥 |
| MIUI 安装绕过 | 开 | 允许 `adb install`；不需要时设 `MIUI_SECURITY_BYPASS=0`，并执行 `setprop persist.security.adbinstall 0`（persist 属性不会因改配置自动清除） |
| Fastboot 绕过 | 关 | 打开后可直接 fastboot 刷机，误操作可能变砖 |
| `ro.debuggable=1` | 关 | 允许 `adb root`，风险更高 |

**加固建议（按优先级）：**

1. **先把公钥配好，再关免授权**（顺序很重要：如果先关掉免授权、重启时又没有任何受信任公钥，
   坏屏设备会直接失去 ADB）。坏屏推荐在 **TWRP** 里做，TWRP 的 shell 已经是 root，
   不需要在手机上点授权：

   ```powershell
   # 1) 推入并立即导入公钥（可多台电脑，重复执行即可）
   adb push "$env:USERPROFILE\.android\adbkey.pub" /tmp/pc.pub
   adb shell "/data/adb/modules/adb_enable/bin/adb-enable addkey /tmp/pc.pub"

   # 2) 确认 adb_keys 里已经有它
   adb shell "cat /data/misc/adb/adb_keys"
   ```

   如果系统已经能正常 adb 且 `su` 已授权，也可以：

   ```powershell
   adb push "$env:USERPROFILE\.android\adbkey.pub" /sdcard/adbkey.pub
   adb shell "su -c '/data/adb/modules/adb_enable/bin/adb-enable addkey /sdcard/adbkey.pub'"
   ```

2. 确认公钥无误后，把 `FORCE_INSECURE_ADB` 改为 `0`：

   ```powershell
   # TWRP 或已授权的 root shell 里
   adb shell "sed -i 's/^FORCE_INSECURE_ADB=.*/FORCE_INSECURE_ADB=0/' /data/adb/adb-enable/config"
   ```

3. 重启：

   ```powershell
   adb reboot
   ```

   重启后 `adbd` 会重新要求授权，只有已信任公钥的电脑能连。
   如果确实不想重启，可以在已授权 root 的 shell 里临时执行：

   ```sh
   su -c '/data/adb/magisk/resetprop -n ro.adb.secure 1'
   su -c 'setprop ctl.restart adbd'
   ```

4. 不需要无线 ADB 时保持 `WIRELESS_ADB=0`；
5. 不要打开 `MIUI_FASTBOOT_BYPASS`，除非你明确需要；
6. 平时不要让手机离开自己的物理控制范围；
7. 彻底不用时，按[第十一节](#uninstall)卸载并关闭相关设置。

> 卸载模块本身**不会**自动关闭 `adb_enabled`，也不会删除公钥；`ro.adb.secure` 会在重启后
> 恢复系统默认。也就是说，卸载后到重启前，免授权仍可能有效。

<a id="cli"></a>
## 八、命令行工具

```sh
su -c '/data/adb/modules/adb_enable/bin/adb-enable status'
su -c '/data/adb/modules/adb_enable/bin/adb-enable run'
su -c '/data/adb/modules/adb_enable/bin/adb-enable addkey /sdcard/adbkey.pub'
su -c '/data/adb/modules/adb_enable/bin/adb-enable wireless on'
su -c '/data/adb/modules/adb_enable/bin/adb-enable config'
su -c '/data/adb/modules/adb_enable/bin/adb-enable log'
```

`status` 会打印 `adb_enabled`、`adbd`、`usb state`、`ro.adb.secure`、
MIUI 两个属性、公钥数量等；`run` 与 Magisk 模块卡片上的“操作”按钮等价。

> 这些命令需要 root。坏屏时如果无法在系统里点 Magisk 的授权弹窗，可以在 **TWRP** 里执行
> （TWRP shell 已是 root，不需要 `su`）；或者把公钥放到 `/data/adb/adb-enable/keys/` 后重启，
> 让模块在开机时自动导入。`/sdcard` 导入默认关闭，原因见[第七节](#security)。

<a id="how"></a>
## 九、工作原理

```
post-fs-data（阻塞、很早）
  ├─ resetprop 写入 persist.sys.usb.config / ro.adb.secure=0 / MIUI 属性
  │    （此阶段绝不能用 setprop，会死锁）
  ├─ 无线 ADB 默认关闭：删除 service/persist 的 tcp 端口属性
  └─ 【可选】合并公钥到 /data/misc/adb/adb_keys
       system:shell 0640 + u:object_r:adb_keys_file:s0
       默认免授权模式下不需要，只作兜底

late_start service（非阻塞）
  ├─ 启动早期尝试 device_provisioned=1（赶在 Setup Wizard 之前）
  ├─ 等 sys.boot_completed=1，再等 BOOT_DELAY
  ├─ settings put global adb_enabled 1（每次调用都经匿名管道，避免 SELinux fd 拦截）
  ├─ 【可选】再同步一次公钥（KEYS_FROM_STORAGE=1 时才读 /sdcard）
  ├─ svc usb setFunctions mtp,adb → 失败则 sys.usb.config none → mtp,adb → adb
  ├─ init.svc.adbd != running 时 setprop ctl.start adbd
  ├─ 免授权模式下重启一次 adbd，确保它读到 ro.adb.secure=0
  ├─ 可选：service.adb.tcp.port=5555 + ctl.restart adbd
  ├─ 可选：input keyevent 224 / wm dismiss-keyguard
  └─ 90 秒内每 15 秒检查 adb_enabled，被改回 0 就重来一遍
```

三个关键细节：

1. **日志重定向必须绕开 binder**。`bcmd()` 里是
   `out=$("$@" </dev/null 2>&1)`，`system_server` 只拿到管道，拿不到 `/data/adb` 文件，
   所以 `Failed transaction (2147483646)` 不会出现。这正是只靠
   `system.prop` 无法可靠开启 ADB 的关键原因。
2. **`svc usb setFunctions` 只接受一个逗号分隔参数**（AOSP `UsbCommand` 只读 `args[2]`），
   所以传 `mtp,adb`，不能传 `mtp adb`。
3. **免授权为什么不需要公钥**：见[6.2](#keys)（Android 13 `adbd` 的 `auth_required` 逻辑）。

<a id="troubleshoot"></a>
## 十、排错

先看日志（TWRP 或正常系统都可以）：

```powershell
adb shell "cat /data/adb/adb-enable/log/adb-enable.log"
adb shell "su -c '/data/adb/modules/adb_enable/bin/adb-enable status'"
```

| 现象 | 排查 / 处理 |
| --- | --- |
| `adb devices` 完全空白 | 看日志里 `status:` 行：`adb_enabled`、`adbd`、`usb_state`。若 `usb_state` 无 `adb`，插拔数据线、换主板后置 USB 口；Windows 设备管理器看有没有黄色感叹号 |
| `unauthorized` | 先看 `adb-enable status` 里的 `ro.adb.secure` 是否为 `0`；若是 `1`（ROM 忽略了该属性），按[第六节](#keys)放置公钥后重启 |
| `offline` | `adb kill-server` 后重插；重启 `adbd`：`adb shell su -c 'setprop ctl.restart adbd'` |
| 能连但 scrcpy 鼠标点不动 | `su -c adb-enable status` 看 `miui adbinput` 是否为 1；确认 `MIUI_SECURITY_BYPASS=1` 并重启 |
| scrcpy 黑屏 | `adb shell input keyevent 224`；或把 `WAKE_SCREEN=1`、`STAY_AWAKE=1` |
| 有密码锁屏，scrcpy 停在锁屏 | 在 scrcpy 窗口里直接用电脑键盘输入 PIN（`persist.security.adbinput=1` 已放开输入注入）；`DISMISS_KEYGUARD` 只对无密码锁屏有效 |
| 停在开机向导 | 日志里找 `provisioned early`；若没有，设 `DISABLE_SETUP_WIZARD_PACKAGES=1` 后重启 |
| 模块看起来没运行 | 确认 `/data/adb/modules/adb_enable/` 存在且没有 `disable` 文件；看 `/data/cache/magisk.log` 是否跑到 `service.d` / 模块脚本 |
| 开机卡死 | Magisk 安全模式（开机按住音量下）会禁用所有模块；进 TWRP 删除 `/data/adb/modules/adb_enable` 即可 |

成功时日志大致如下（默认无公钥的免授权路径）：

```text
... [post-fs-data] keys: no valid key found, /data/misc/adb/adb_keys left untouched
... [service] setup wizard: provisioned early (attempt 1)
... [service] settings: global/adb_enabled=1 OK
... [service] usb: svc usb setFunctions mtp,adb worked
... [service] adbd: now 'running'
... [service] adbd: restarting once to apply ro.adb.secure=0
... [service] status: adb_enabled=1 dev_options=1 provisioned=1 setup=1
... [service] status: adbd=running usb_config=mtp,adb usb_state=mtp,adb ffs=1
... [service] status: adb_secure=0 debuggable= miui_input=1 miui_install=1 keys=0 wireless=service:-1,persist:-1
```

如果你用了公钥，前两行会变成 `keys: installed N key(s)` / `keys: unchanged`，其余一致。

如果信任库被误改，可以用模块自动留下的备份恢复（TWRP 里，root）：

```sh
cp -f /data/misc/adb/adb_keys.bak /data/misc/adb/adb_keys
chown 1000:2000 /data/misc/adb/adb_keys
chmod 0640 /data/misc/adb/adb_keys
chcon u:object_r:adb_keys_file:s0 /data/misc/adb/adb_keys
```

只有在 `KEYS_BACKUP=1`（默认）且确实发生过一次写入时才会有 `.bak`。

<a id="uninstall"></a>
## 十一、卸载

Magisk 里卸载模块即可。卸载会清除并关闭 TCP 端口（`service.adb.tcp.port` /
`persist.adb.tcp.port`）：系统运行中卸载会重启 `adbd` 立即关闭监听，开机阶段卸载则不会在
本次启动恢复。但**不会自动关闭 ADB、不会删除公钥、也不会清除 `persist.security.*`**
（这是故意的：坏屏设备不能因为误卸载模块而彻底失联）。

如果要彻底还原（在 TWRP 或已授权的 root shell 里执行）：

```sh
# 1) 系统开关
su -c 'settings put global adb_enabled 0'
su -c 'settings put global development_settings_enabled 0'
su -c 'settings put global device_provisioned 0'
su -c 'settings put secure user_setup_complete 0'
su -c 'settings put global setup_wizard_has_run 0'
su -c 'settings put global stay_on_while_plugged_in 0'

# 2) persist 属性
su -c 'setprop persist.security.adbinput 0'
su -c 'setprop persist.security.adbinstall 0'
su -c 'setprop persist.service.debuggable 0'
su -c 'setprop persist.fastboot.enable 0'
su -c 'setprop persist.service.adb.enable 0'
su -c 'setprop persist.sys.usb.config mtp'
su -c 'setprop persist.adb.tcp.port -1'
su -c 'setprop service.adb.tcp.port -1'

# 3) 删除模块保存的公钥来源，再删设备信任库
su -c 'rm -f /data/adb/adb-enable/keys/* /data/adb/adb-enable/adb_keys'
su -c 'rm -f /data/misc/adb/adb_keys /data/misc/adb/adb_keys.bak'
```

如果曾用过 `KEYS_FROM_STORAGE=1`，还要删除 `/sdcard/adbkey.pub`、`/sdcard/adb_keys`、
`/sdcard/adb-enable/keys/*` 等副本，否则下次开机还会被导入。

> `device_provisioned` / `user_setup_complete` 改回 0 后，开机向导不一定会自动重新出现；
> 需要重新走向导时通常得恢复出厂设置。`ro.adb.secure` 在重启后恢复系统默认值；
> `adb_enabled`、公钥和 `persist.*` 不会自动恢复，必须显式处理。

> **注意：** 如果你没有配置任何公钥，卸载后重启会失去 ADB（免授权模式随
> `ro.adb.secure` 恢复而失效，又没有任何被信任的电脑）。请先确认还有 TWRP 等恢复手段，
> 或先按[第六节](#keys)配好公钥再卸载。

卸载后如果还需要 ADB，可以先在 TWRP 里把 `/data/misc/adb/adb_keys` 备份走。

<a id="dev"></a>
## 十二、开发 / 构建 / 测试

```
module/                     # 模块源码（zip 根目录内容）
├── module.prop
├── common.sh               # 共享逻辑（日志 / 配置 / 公钥 / settings / USB）
├── post-fs-data.sh
├── service.sh
├── action.sh               # Magisk 模块卡片的“操作”按钮
├── customize.sh            # 安装时建目录、生成默认配置、导入公钥
├── uninstall.sh
├── skip_mount
├── bin/adb-enable
├── keys/README.txt
└── META-INF/com/google/android/{update-binary,updater-script}

build.py                    # 打包：dist/ADB-Enable-v1.0.0.zip（含执行位）
tests/run_tests.sh          # 主机侧测试：dash + BusyBox ash + 假 Android 环境
```

```bash
python3 build.py
bash tests/run_tests.sh

# 用真实 BusyBox ash 再跑一遍（模拟 Magisk 的 boot script 环境）
printf '#!/bin/sh\nexec /path/to/busybox ash "$@"\n' > /tmp/bbash
chmod +x /tmp/bbash
SH=/tmp/bbash bash tests/run_tests.sh
```

测试覆盖：早期属性、零公钥启动、公钥合并/去重/CRLF/非法输入/未知类型旧公钥保留、
超大与符号链接公钥跳过、备份/chcon 失败时不覆盖原信任库、配置不执行代码、
非法 USB_CONFIG 回退、settings 重试、
USB 两种路径、adbd、无线 ADB、跳过向导、全开关关闭、安装器配置/公钥导入、
CLI、zip 结构/执行位、以及**负向测试**：任何一个 binder 命令如果把日志文件
当 stdout（`settings ... >> log`），测试里的 stub 会直接以 rc=97 失败。

> 说明：以上逻辑即模块的完整实现，但本人没有物理设备可刷。
> 首次使用请先在 TWRP 下备份，并保留 `adb` 可用这一条退路。

<a id="thanks"></a>
## 十三、致谢

- MIUI 安全属性思路参考 [CHERWING/xiaomi_usb_security_bypass](https://github.com/CHERWING/xiaomi_usb_security_bypass)；
- Magisk 模块格式参考官方 [Developer Guides](https://topjohnwu.github.io/Magisk/guides.html)。
