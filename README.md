# ULSEE Windows 11 WinPE USB/PXE Deployment Kit

这套文件用于基于 Windows 11 ISO 自带的 WinPE 自动部署自定义镜像。它不替换 `sources\install.wim`，也不走 Windows Setup 正常安装流程；WinPE 启动后会运行 `deploy.bat`，清空目标机器 `Disk 0`，创建 UEFI/GPT 分区，将 `Images\install.wim` 通过 DISM 应用到 `W:`，写入 UEFI 启动文件，然后重启进入 Windows。

## 方式A：自动部署（默认主流程）

1. 使用 Windows 11 24H2 ISO 正常制作启动 U 盘。
2. 建议 U 盘使用 NTFS，容量 64GB 或 128GB。
3. 从 GitHub 下载或 clone 本仓库。
4. 运行复制工具，例如：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\tools\copy-to-usb.ps1 -UsbDrive E: -WimPath D:\ghost\install.wim
   ```

5. U 盘根目录需要存在：

   ```text
   Autounattend.xml
   deploy.bat
   diskpart-uefi.txt
   unattend.xml
   Images\install.wim
   Windows\Setup\Scripts\SetupComplete.cmd
   ```

   也可以手动把定制镜像放到：

   ```text
   U盘:\Images\install.wim
   ```

6. 保持 U 盘根目录存在：

   ```text
   U盘:\Autounattend.xml
   ```

7. 从 U 盘以 UEFI 模式启动目标电脑。
8. WinPE 会通过 `Autounattend.xml` 自动执行：

   ```cmd
   cmd /c "%configsetroot%\deploy.bat" /auto
   ```

9. 自动部署完成后会重启进入 Windows。

警告：方式A启动后不需要按 `Shift+F10`，也不会询问确认；自动部署会清空 Disk 0，`/auto` 模式会自动清空目标机器的 `Disk 0` 并部署系统。

部署过程会执行以下动作：

- 清空 `Disk 0`
- 创建 UEFI/GPT 分区，EFI 使用 `S:`，Windows 临时盘符使用 `W:`
- 使用 `dism /Apply-Image` 应用 `Images\install.wim`
- 将 `unattend.xml` 复制到 `W:\Windows\Panther\Unattend.xml`
- 如果存在 `Windows\Setup\Scripts`，复制到 `W:\Windows\Setup\Scripts\`
- 执行 `bcdboot W:\Windows /s S: /f UEFI`
- 执行 `wpeutil reboot`

目标系统的 `unattend.xml` 不创建本地账号、不启用内置 Administrator、不加域。它会跳过 OOBE，并自动登录镜像中已经存在的本地管理员账号 `ulsee`，密码为 `p@SSW0RD!`，登录次数为 1。

## 使用复制工具写入 U 盘

在本机仓库目录中运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\copy-to-usb.ps1 -UsbDrive E: -WimPath D:\ghost\install.wim
```

这个工具会把 `Autounattend.xml`、`deploy.bat`、`diskpart-uefi.txt`、`unattend.xml`、`Windows` 目录复制到 U 盘根目录，创建 `Images` 目录，并在提供 `-WimPath` 时把镜像复制为 `U盘:\Images\install.wim`。它不会复制 `.gitkeep`，不会执行 `deploy.bat`，不会执行 `diskpart`，也不会执行 DISM。

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

PXE 模式下，部署文件和 `Images\install.wim` 应位于共享目录中，且 `deploy.bat` 会通过 `%~dp0` 自动识别自身所在目录，不依赖固定 U 盘盘符。

## 目录结构

```text
Autounattend.xml
deploy.bat
diskpart-uefi.txt
unattend.xml
README.md
.gitignore
Images\
  .gitkeep
Windows\
  Setup\
    Scripts\
      SetupComplete.cmd
tools\
  copy-to-usb.ps1
```

## 安全边界

- 不要把真实 `install.wim` 提交到 git。
- 不要在生产机器外误启动带有 `Autounattend.xml` 的 U 盘。
- 不要把域账号密码写入这些文件。
- 本方案不启用内置 Administrator。
- 本方案不包含自动加域逻辑。
- 本方案不让 Windows Setup 自己安装系统。
