# ULSEE Windows 11 WinPE USB/PXE Deployment Kit

这套文件用于基于 Windows 11 ISO 自带的 WinPE 自动部署自定义镜像。它不走 Windows Setup 正常安装流程；WinPE 启动后会运行 `deploy.bat`，清空目标机器 `Disk 0`，创建 UEFI/GPT 分区，将选中的 `install.wim` 通过 DISM 应用到 `W:`，写入 UEFI 启动文件，然后重启进入 Windows。

## 推荐方式：boot.wim 直启无人值守模式

这个模式会 patch Windows 安装 U 盘的 `sources\boot.wim`，让 WinPE 启动后直接运行：

```cmd
deploy.bat /auto
```

它不再依赖 Windows Setup 作为主入口，也不再依赖 `Autounattend.xml` 启动部署流程。启动后会自动清空目标机器 `Disk 0`，只允许在可以清空的测试机上验证。

推荐流程：

1. 使用 Windows 11 ISO 正常制作启动 U 盘。
2. 把定制镜像放到以下任一位置：

   ```text
   U盘:\sources\install.wim
   U盘:\Images\install.wim
   ```

3. 复制 U-Create 工具到 U 盘：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\tools\copy-to-usb.ps1 -UsbDrive D:
   ```

4. Patch `boot.wim`，默认 patch Index 2：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\tools\patch-boot-wim.ps1 -UsbDrive D: -Index 2
   ```

5. 运行诊断：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\tools\collect-usb-deploy-info.ps1 -UsbDrive D:
   ```

6. 只有诊断显示：

   ```text
   READY FOR TRUE UNATTENDED TEST DEPLOYMENT
   ```

   才使用测试机从该 U 盘启动。

如果 patch 后仍进入 Windows Setup，可以尝试：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\patch-boot-wim.ps1 -UsbDrive D: -Index 1 -Force
```

或 patch 所有 boot.wim index：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\patch-boot-wim.ps1 -UsbDrive D: -PatchAllIndexes -Force
```

如果要恢复最近一次备份：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\patch-boot-wim.ps1 -UsbDrive D: -RestoreLatestBackup
```

为防止同一个 U 盘重复自动清盘，部署成功后会写入：

```text
U盘:\DeployLogs\deploy-success.flag
```

如果要部署下一台机器，需要先删除：

```text
U盘:\DeployLogs\deploy-success.flag
```

`boot.wim` direct mode 下，`Autounattend.xml` 不是主入口。`patch-boot-wim.ps1` 默认会把 U 盘根目录的 `Autounattend.xml` 改名为 `Autounattend.setup-mode.xml`，避免 Windows Setup 干扰；如果确实要保留，可传 `-KeepAutounattend`。

## 旧方式：Autounattend 自动部署（legacy）

1. 使用 Windows 11 24H2 ISO 正常制作启动 U 盘。
2. 建议 U 盘使用 NTFS，容量 64GB 或 128GB。
3. 可以直接使用 U 盘已有的 `sources\install.wim`，不需要额外创建 `Images\install.wim`。
4. 从 GitHub 下载或 clone 本仓库。
5. 运行复制工具，把部署工具复制到 U 盘根目录，例如：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\tools\copy-to-usb.ps1 -UsbDrive D:
   ```

6. U 盘根目录需要存在：

   ```text
   Autounattend.xml
   deploy.bat
   diskpart-uefi.txt
   unattend.xml
   Windows\Setup\Scripts\SetupComplete.cmd
   ```

   镜像文件可以位于：

   ```text
   U盘:\sources\install.wim
   U盘:\Images\install.wim
   ```

   `deploy.bat` 的镜像优先级是：

   ```text
   1. Images\install.wim
   2. sources\install.wim
   ```

   如果要使用外部 WIM，仍可传入 `-WimPath`，复制工具会把它放到 `Images\install.wim`：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\tools\copy-to-usb.ps1 -UsbDrive D: -WimPath D:\ghost\install.wim
   ```

7. 保持 U 盘根目录存在：

   ```text
   U盘:\Autounattend.xml
   ```

8. 从 U 盘以 UEFI 模式启动目标电脑。
9. WinPE 会通过 `Autounattend.xml` 自动执行：

   ```cmd
   cmd /c "%configsetroot%\deploy.bat" /auto
   ```

10. 自动部署完成后会重启进入 Windows。

警告：方式A启动后不需要按 `Shift+F10`，也不会询问确认；自动部署会清空 Disk 0，`/auto` 模式会自动清空目标机器的 `Disk 0` 并部署系统。

部署过程会执行以下动作：

- 清空 `Disk 0`
- 创建 UEFI/GPT 分区，EFI 使用 `S:`，Windows 临时盘符使用 `W:`
- 使用 `dism /Apply-Image` 应用镜像，优先 `Images\install.wim`，其次 `sources\install.wim`
- 将 `unattend.xml` 复制到 `W:\Windows\Panther\Unattend.xml`
- 如果存在 `Windows\Setup\Scripts`，复制到 `W:\Windows\Setup\Scripts\`
- 执行 `bcdboot W:\Windows /s S: /f UEFI`
- 执行 `wpeutil reboot`

目标系统的 `unattend.xml` 不创建本地账号、不启用内置 Administrator、不加域。它会跳过 OOBE，并自动登录镜像中已经存在的本地管理员账号 `ulsee`，密码为 `p@SSW0RD!`，登录次数为 1。

## 使用复制工具写入 U 盘

在本机仓库目录中运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\copy-to-usb.ps1 -UsbDrive D:
```

这个工具会把 `Autounattend.xml`、`deploy.bat`、`diskpart-uefi.txt`、`unattend.xml`、`Windows` 目录复制到 U 盘根目录。如果没有提供 `-WimPath`，它不会创建 `Images\install.wim`，而是检查 U 盘是否已有 `sources\install.wim`；当前常见做法就是直接使用 Windows 安装 U 盘里的 `sources\install.wim`。

如果要使用外部 WIM，仍可传：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\copy-to-usb.ps1 -UsbDrive D: -WimPath D:\ghost\install.wim
```

提供 `-WimPath` 时，复制工具会把镜像复制为 `U盘:\Images\install.wim`。它不会复制 `.gitkeep`，不会执行 `deploy.bat`，不会执行 `diskpart`，也不会执行 DISM。

## 诊断当前 U 盘状态

如果需要检查本机 Windows 启动 U 盘和 ULSEE 部署文件是否准备正确，可以运行只读诊断脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\collect-usb-deploy-info.ps1
```

指定某个 U 盘盘符：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\collect-usb-deploy-info.ps1 -UsbDrive D:
```

脚本会在当前目录生成 `USB_DEPLOY_DIAG_*.txt` 报告。它只收集卷信息、部署文件状态、镜像文件位置、脚本/XML 检查结果，并且只允许执行 `dism /Get-WimInfo`。它不会执行 `deploy.bat`、`diskpart`、`dism /Apply-Image`、`bcdboot`，也不会复制或删除镜像文件。

如果镜像很大，默认不会计算哈希；需要时可以显式加入：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\collect-usb-deploy-info.ps1 -UsbDrive D: -IncludeHash
```

运行后可以把生成的 `USB_DEPLOY_DIAG_*.txt` 发给 ChatGPT 分析。

## 先梳理 U 盘结构，再决定是否部署

在还不确定定制镜像应该放在 `Images\install.wim` 还是 `sources\install.wim` 时，先不要直接启动目标机器。请先在本机运行只读诊断：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\collect-usb-deploy-info.ps1 -UsbDrive D:
```

脚本会生成：

```text
USB_DEPLOY_DIAG_*.txt
```

把这份报告发给 ChatGPT 分析，用来判断：

- 当前 U 盘是否是完整 Windows 启动 U 盘
- U-Create 部署工具是否已经复制到 U 盘根目录
- 当前有效镜像在 `Images\install.wim` 还是 `sources\install.wim`
- 当前 `deploy.bat` 的实际逻辑是否和 U 盘镜像位置匹配
- 是否应该继续使用 `Images\install.wim`
- 是否正在使用 `sources\install.wim` fallback
- 是否应该删除或保留 `sources\install.wim`
- 是否可以开启 `Autounattend.xml` 自动部署

在 ChatGPT 确认前，不要从该 U 盘启动目标机器。如果 U 盘根目录存在 `Autounattend.xml`，从该 U 盘启动可能自动清空目标机器的 `Disk 0`。

## 备用手动方式（故障排查）

如果需要临时禁用自动部署，把 U 盘根目录的：

```text
Autounattend.xml
```

改名为：

```text
Autounattend.off
```

然后从 U 盘启动 WinPE，按 `Shift+F10` 打开命令提示符，运行：

```cmd
for %i in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist "%i:\deploy.bat" "%i:\deploy.bat"
```

手动模式会提示将清空 `Disk 0`，并需要确认后继续。

## PXE 使用方式

1. PXE 启动 WinPE。
2. 在 WinPE 中执行：

   ```cmd
   wpeinit
   ```

3. 映射共享，例如：

   ```cmd
   net use Z: \\server\ghost /user:domain\user password
   ```

4. 执行：

   ```cmd
   Z:\deploy.bat /auto
   ```

PXE 模式下，部署文件和镜像文件应位于共享目录中。`deploy.bat` 会通过 `%~dp0` 自动识别自身所在目录，不依赖固定 U 盘盘符，并按 `Images\install.wim`、`sources\install.wim` 的顺序选择镜像。

## U 盘最终关键结构

```text
Autounattend.xml
deploy.bat
diskpart-uefi.txt
unattend.xml
Images\
  install.wim          （可选，使用 -WimPath 时创建）
sources\
  boot.wim
  install.wim         （Windows 安装 U 盘自带，可直接用于部署）
Windows\
  Setup\
    Scripts\
      SetupComplete.cmd
```

不要把真实 `.wim`、`.esd`、`.swm` 文件提交到 git。

## 安全边界

- 不要把真实 `install.wim` 提交到 git。
- 不要在生产机器外误启动带有 `Autounattend.xml` 的 U 盘。
- 不要把域账号密码写入这些文件。
- 本方案不启用内置 Administrator。
- 本方案不包含自动加域逻辑。
- 本方案不让 Windows Setup 自己安装系统。
