# PDF 工具组（Windows 10 便携 BAT 版）

这是 Windows 10 x64、本机离线运行、免安装的便携工具组，包含两个独立入口：`PDF权限处理工具.bat` 和 `PDF去水印工具.bat`。目标机无需安装 Python 或 qpdf，运行时均随发布包提供。

## 下载和使用

普通用户请从 GitHub Releases 下载 `PDF权限处理工具_BAT版.zip`，完整解压后使用，不要只复制 BAT。

| 入口 | 用途 | 同目录输出 |
| --- | --- | --- |
| `PDF权限处理工具.bat` | 为可以直接打开、但受到普通编辑或注释权限限制的 PDF 生成新副本，供福昕阅读器重新尝试“打字机”等注释功能 | `原文件名_可注释.pdf` |
| `PDF去水印工具.bat` | 清除明确标记的结构化水印，适用范围见下文 | `原文件名_去水印.pdf` |

两个工具均支持双击后批量选择 PDF，或在资源管理器中多选 PDF 后拖入对应 BAT。开始前会提示原件与数字签名风险，确认后处理。

输出保存在原文件所在目录。发生同名碰撞时自动递增为 `_可注释_2.pdf`、`_可注释_3.pdf`，或 `_去水印_2.pdf`、`_去水印_3.pdf`。不覆盖原件，也不覆盖已有输出；逐文件隔离，单个失败不影响批次中的其他文件。

## 去水印范围

`PDF去水印工具.bat` 只清除内容流中明确标记为 `/Artifact` 且 `/Subtype /Watermark` 的结构化水印。不根据颜色、角度、透明度或重复文字猜测。

不处理扫描图片/像素水印、普通正文、页眉页脚。即使肉眼可见水印，缺少上述结构标记时也会跳过，且不生成副本。成功表示已移除识别到的结构化水印块，不保证清除页面上其他形式的水印；请检查输出内容。

检测到标记不等于一定处理，安全优先：即使检测到 /Artifact 且 /Subtype /Watermark，如果水印位于后续正文之前，且包含可能跨边界影响文本位置、当前路径或裁剪等状态的内容，工具无法证明删除安全时会跳过，不生成副本。

详细说明见 [`src/使用说明.txt`](src/使用说明.txt)。

## 安全边界

- 仅限处理用户有权修改的文件。
- 不猜测、不破解未知的打开密码；遇到需要打开密码的文件不继续处理。
- 文件只在本机处理，不上传 PDF，不调用在线服务，不采集文件内容。
- 不修改或删除原文件；一个文件失败不会中断其他文件。
- 重新生成的副本可能使数字签名或认证签名失效，不保证保留签名有效性。
- 权限处理后仍无法使用福昕“打字机”时，原因可能不是普通 PDF 权限限制。

## 技术结构

```text
src/
├─ PDF权限处理工具.bat       # 权限入口
├─ PDF去水印工具.bat         # 结构化水印入口
├─ tools/
│  ├─ pdf_tool.ps1           # 权限处理
│  └─ watermark_ui.ps1       # 选择文件、批次调度与输出校验
├─ watermark_core/
│  └─ watermark_core.py      # 结构化水印核心源码
└─ 使用说明.txt
scripts/
├─ Fetch-Qpdf.ps1            # 固定版本与 SHA-256 校验
├─ Build-WatermarkCore.ps1   # 构建 Windows x64 独立 EXE
├─ requirements-watermark-build.txt  # direct：直接依赖固定版本
├─ requirements-watermark-lock.txt   # lock：完整依赖与 SHA-256
└─ Build-Portable.ps1        # 组装目录、manifest 与 Release ZIP
tests/
├─ watermark_core/test_watermark_core.py
├─ Run-Tests.ps1             # 权限工具与交付验收
├─ Run-WatermarkTests.ps1    # 水印调度与交付验收
└─ Test-FetchIntegrity.ps1
third_party/
├─ pypdf-LICENSE.txt
└─ PyInstaller-COPYING.txt
```

发布包中的 `watermark/watermark_core.exe` 是 PyInstaller 构建的 Windows x64 独立 EXE，目标机无需 Python。qpdf 仍随包提供，用于权限处理及水印输出校验。第三方许可证复制到发布包 `licenses/` 目录。

核心安全门：“页面内容流末尾”指内容操作的顺序，与水印在页面上的视觉位置无关。不在页面内容流末尾的候选仅在绘图状态严格隔离且操作安全时处理；位于页面内容流末尾的候选仍支持。无法确认删除不会影响后续内容时，跳过整个文件且不生成副本。

BAT 内容保持纯 ASCII、无 BOM，不使用 `chcp 65001` 或延迟扩展；含中文的 PowerShell 脚本使用 UTF-8 BOM，以兼容 Windows PowerShell 5.1。

## 构建

构建环境为 Windows 10 x64，构建机需安装 Python 3.10 x64 与 `py` launcher（启动器）。在仓库根目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Portable.ps1
```

构建脚本会：

1. 获取 qpdf 12.4.2 官方 `msvc64` ZIP，校验固定 SHA-256，重解压并验证精确版本；
2. 校验 direct/lock 版本一致性，按 SHA-256 哈希锁安装完整构建依赖；
3. 在独立 Python 3.10 构建环境中，用 PyInstaller 构建并验证水印核心 EXE；
4. 组装两个入口、运行时、使用说明及第三方许可证；
5. 生成 `dist/PDF权限处理工具_BAT版/`、哈希 manifest `SHA256SUMS.txt` 和 Release ZIP。

构建时获取依赖需要网络；解压后的工具在目标机运行时本机离线，无需安装 Python。

## 测试

先运行上述 `Build-Portable.ps1`，生成依赖和交付目录，再执行：

```powershell
& .\.build\watermark-core\venv\Scripts\python.exe -m unittest discover -s .\tests\watermark_core -v
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -DeliverySmokeTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-WatermarkTests.ps1 -DeliverySmokeTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FetchIntegrity.ps1
```

源码核心测试使用构建脚本创建的虚拟环境，其中已安装锁定版本 pypdf。核心测试覆盖结构标记识别、内容保留和跳过等行为；PowerShell 测试覆盖调度、同名递增、中文和 shell 特殊字符路径、原件不变、逐文件隔离、错误映射及输出校验。交付模式从解压 ZIP 中运行真实 BAT，覆盖随包核心 EXE、真实 qpdf 与清单验证；完整性测试覆盖依赖篡改后的恢复。

## 第三方软件

- qpdf 12.4.2：官方 Windows x64 运行时，LICENSE、NOTICE 及版权信息随包提供。[官方项目](https://github.com/qpdf/qpdf)。
- pypdf 6.10.2：BSD-3-Clause，许可证见 `licenses/pypdf-LICENSE.txt`。
- PyInstaller 6.20.0：GPL-2.0-or-later，带 bootloader exception；完整条款见 `licenses/PyInstaller-COPYING.txt`。

上述许可说明针对第三方组件；仓库目前未提供项目自身的 `LICENSE`，不能据此推定项目代码的授权范围。

## 发布

`dist/` 和 `vendor/` 不提交到 Git。发布者应从干净工作区运行构建与测试，然后把 `dist/PDF权限处理工具_BAT版.zip` 作为 GitHub Release 附件上传。
