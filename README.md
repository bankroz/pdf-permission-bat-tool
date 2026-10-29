# PDF 权限处理与结构化水印清理工具

面向 **Windows 10 64 位（x64）** 的绿色便携 PDF 工具组。本机离线运行、免安装，目标电脑无需另外安装 Python 或 qpdf。

本项目提供两个独立 BAT：

| 我要做什么 | 应该运行哪个文件 | 生成的副本 |
|---|---|---|
| PDF 可以打开，但编辑、注释或“打字机”功能受限 | **`PDF权限处理工具.bat`** | `原文件名_可注释.pdf` |
| 删除 `/Artifact /Subtype /Watermark` 结构化水印 | **`PDF去水印工具.bat`** | `原文件名_去水印.pdf` |

> 原文件不会被覆盖。工具只生成新副本。

## 立即下载

### 推荐：下载完整绿色版

**[⬇ 下载 Windows 10 x64 完整版 ZIP（v0.2.0）](https://github.com/bankroz/pdf-permission-bat-tool/releases/download/v0.2.0/PDF-Permission-Tool-Windows10-x64-v0.2.0.zip)**

[查看 v0.2.0 发布说明](https://github.com/bankroz/pdf-permission-bat-tool/releases/tag/v0.2.0) · [查看全部版本](https://github.com/bankroz/pdf-permission-bat-tool/releases)

下载后必须**完整解压 ZIP**，不要只把 BAT 单独复制出来。BAT 需要使用同目录中的 `tools`、`qpdf` 和 `watermark` 文件。

## BAT 文件到底在哪里

### 情况一：你下载的是 Release ZIP

解压后打开最外层的 `PDF权限处理工具_BAT版` 文件夹，两个 BAT 就在第一层：

```text
PDF权限处理工具_BAT版\
├─ PDF权限处理工具.bat      ← 解除普通编辑/注释权限限制
├─ PDF去水印工具.bat        ← 删除支持的结构化水印
├─ 使用说明.txt
├─ tools\
├─ qpdf\
├─ watermark\
└─ licenses\
```

不需要进入 `tools`、`qpdf` 或 `watermark` 子目录。

### 情况二：你在本地源码目录中

已经构建好的、可以直接运行的 BAT 位于：

```text
dist\PDF权限处理工具_BAT版\PDF权限处理工具.bat
dist\PDF权限处理工具_BAT版\PDF去水印工具.bat
```

完整绿色压缩包位于：

```text
dist\PDF权限处理工具_BAT版.zip
```

仓库中的 BAT 源码可直接点击查看：

- [查看 `PDF权限处理工具.bat` 源码](src/PDF权限处理工具.bat)
- [查看 `PDF去水印工具.bat` 源码](src/PDF去水印工具.bat)
- [查看完整中文使用说明](src/使用说明.txt)

**注意：`src` 里的 BAT 只是源码入口，不能脱离运行时单独使用。普通用户应下载 Release ZIP，或运行本地 `dist` 目录中的完整版本。**

## 三步开始使用

1. 下载并完整解压 ZIP。
2. 根据任务双击 `PDF权限处理工具.bat` 或 `PDF去水印工具.bat`。
3. 在文件选择窗口中一次选择一个或多个 PDF，阅读风险提示后确认处理。

也可以在资源管理器中多选 PDF，再拖到对应 BAT 文件上。

处理结果保存在**原 PDF 所在目录**，不会保存到工具目录。

## 输出规则

| 工具 | 第一次输出 | 同名文件已存在时 |
|---|---|---|
| 权限处理 | `报告_可注释.pdf` | `报告_可注释_2.pdf`、`报告_可注释_3.pdf`…… |
| 去水印 | `报告_去水印.pdf` | `报告_去水印_2.pdf`、`报告_去水印_3.pdf`…… |

- 不修改或删除原 PDF。
- 不覆盖已有输出。
- 单个文件失败不会中断同一批次中的其他文件。
- 输出通过结构检查后才会保留为最终文件。
- 去水印工具未识别到支持的水印时，不生成空副本或伪成功文件。

## 两个工具分别能做什么

### PDF 权限处理工具

适用于 PDF **可以直接打开**，但存在普通编辑、注释、复制或打印权限限制的情况。工具会重新生成一个不带这些普通权限限制的副本。

典型场景：

- 福昕阅读器中无法使用“打字机”或部分注释功能。
- PDF 显示不允许编辑、注释或复制。
- 希望保留原件，另生成一个可继续处理的副本。

它不能：

- 猜测或破解未知的打开密码。
- 保证解除数字签名、认证签名或 DRM 类限制。
- 保证所有阅读器都开放相同的编辑能力。

### PDF 去水印工具

只删除 PDF 内容流中明确标记为：

```text
/Artifact
/Subtype /Watermark
```

的结构化水印。

它不会根据颜色、角度、透明度或重复文字猜测水印，也不会删除：

- 扫描件中的图片/像素水印。
- 已经合并进普通正文的文字或图形。
- 普通页眉、页脚和背景图片。
- 无法证明安全删除的内容块。

即使肉眼能看到水印，只要 PDF 没有对应结构标记，工具也会跳过。识别到结构标记后，如果删除可能影响后续正文、文本位置、路径或裁剪状态，工具同样会安全跳过，不生成副本。

## 批量处理

两个 BAT 都支持批量选择：

- 双击 BAT 后，在文件选择窗口中按住 `Ctrl` 或 `Shift` 多选 PDF。
- 或在资源管理器中多选 PDF，拖放到 BAT 上。

每个 PDF 独立处理并独立报告结果。一个文件失败不会让整批任务中止。

## 常见问题

### 1. 双击 BAT 后提示缺少 qpdf 或 watermark_core

说明工具包没有完整解压，或者只复制了 BAT。请重新下载完整 ZIP，并将整个文件夹完整解压后运行。

### 2. PDF 需要输入密码才能打开

本工具不猜测、不破解未知的打开密码，因此会停止处理。只有能直接打开的 PDF 才属于权限处理工具的目标范围。

### 3. 权限副本生成成功，但福昕仍不能使用“打字机”

原因可能不是普通 PDF 权限限制，也可能与数字签名、认证限制、PDF 内部结构或福昕当前工具状态有关。请保留原件，并检查新副本的文档属性。

### 4. 看得见水印，但工具提示未识别或跳过

这通常表示水印是扫描图片、普通正文、背景图，或者没有 `/Artifact /Subtype /Watermark` 结构标记。此类水印不在本工具的安全处理范围内。

### 5. 输出文件在哪里

输出始终保存在原 PDF 的同一目录，而不是 BAT 所在目录。

### 6. 能否只把 BAT 复制到桌面

不能。BAT 依赖同一工具包中的 PowerShell 脚本、qpdf、去水印核心和许可证文件。可以把**整个解压后的文件夹**移动到桌面或 U 盘。

## 数据安全与使用边界

- 仅限处理你有权访问和修改的 PDF。
- 文件只在本机处理，不上传 PDF，不调用在线 PDF 服务。
- 不采集 PDF 内容，不保存文件清单或密码。
- 不修改、删除或覆盖原件。
- 重新生成 PDF 可能使原有数字签名或认证签名失效。
- 建议先用副本验证页面、附件、书签、表单和签名状态。

## 系统要求

- Windows 10 64 位（x64）。
- Windows PowerShell 5.1。
- 对原 PDF 所在目录具有写入权限。
- 无需管理员权限。
- 无需安装 Python、qpdf 或其他运行环境。
- 正式发布包运行时无需联网。

## 发布包包含什么

```text
PDF权限处理工具_BAT版\
├─ PDF权限处理工具.bat
├─ PDF去水印工具.bat
├─ 使用说明.txt
├─ SHA256SUMS.txt
├─ tools\
│  ├─ pdf_tool.ps1
│  └─ watermark_ui.ps1
├─ qpdf\bin\
├─ watermark\watermark_core.exe
└─ licenses\
```

发布包带有 `SHA256SUMS.txt`，用于核对随包关键文件是否完整。

## 开发者：源码结构

```text
src/
├─ PDF权限处理工具.bat
├─ PDF去水印工具.bat
├─ tools/
│  ├─ pdf_tool.ps1
│  └─ watermark_ui.ps1
├─ watermark_core/
│  └─ watermark_core.py
└─ 使用说明.txt
scripts/
├─ Fetch-Qpdf.ps1
├─ Build-WatermarkCore.ps1
├─ Build-Portable.ps1
├─ requirements-watermark-build.txt
└─ requirements-watermark-lock.txt
tests/
├─ watermark_core/
├─ Run-Tests.ps1
├─ Run-WatermarkTests.ps1
└─ Test-FetchIntegrity.ps1
```

设计与实现文档：

- [权限处理工具设计](docs/superpowers/specs/2026-10-29-pdf-permission-bat-design.md)
- [权限处理工具实现计划](docs/superpowers/plans/2026-10-29-pdf-permission-bat-implementation.md)
- [结构化去水印设计](docs/superpowers/specs/2026-10-29-structured-watermark-removal-design.md)
- [结构化去水印实现计划](docs/superpowers/plans/2026-10-29-structured-watermark-removal-implementation.md)

## 开发者：构建完整绿色包

发布构建环境为 Windows 10 x64，需要 CPython 3.10.11 x64 和 `py` launcher。构建脚本会固定并校验依赖版本、下载 qpdf、构建去水印核心、复制许可证并生成 ZIP。

在仓库根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Portable.ps1
```

构建产物：

```text
dist\PDF权限处理工具_BAT版\
dist\PDF权限处理工具_BAT版.zip
```

构建时需要联网获取依赖；构建完成后的发布包可离线运行。

## 开发者：运行测试

先完成构建，再在仓库根目录运行：

```powershell
& .\.build\watermark-core\venv\Scripts\python.exe -m unittest discover -s .\tests\watermark_core -v
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -DeliverySmokeTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-WatermarkTests.ps1 -DeliverySmokeTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FetchIntegrity.ps1
```

测试覆盖：

- qpdf 固定版本和下载完整性。
- 中文、空格和 shell 特殊字符路径。
- 批量处理与逐文件错误隔离。
- 同名输出自动递增。
- 原件不变与输出结构校验。
- 结构化水印识别、删除和安全跳过。
- Release ZIP 中真实 BAT、qpdf 和独立去水印 EXE 的交付验收。

## 第三方软件与许可证

- [qpdf 12.4.2](https://github.com/qpdf/qpdf)：Apache-2.0，发布包内含 LICENSE、NOTICE 和版权信息。
- pypdf 6.10.2：BSD-3-Clause。
- PyInstaller 6.20.0：GPL-2.0-or-later，带 bootloader exception。
- CPython 3.10.11 运行时：PSF 及 Windows 发行版随附条款。
- typing_extensions 4.16.0：许可证原文随包提供。

完整第三方许可证位于发布包的 `licenses` 目录。

上述许可仅对应第三方组件。仓库目前没有提供项目自身的 `LICENSE`，不能据此推定项目代码的授权范围。

## 项目状态

- 当前发布版本：`v0.2.0`
- 目标平台：Windows 10 x64
- 运行方式：绿色便携、本机离线
- 原件策略：只读输入，始终生成新副本
