# PDF 权限处理工具（Windows 10 便携 BAT 版）

一个本机运行、免安装的 Windows 10 x64 小工具。它调用随目录附带的 qpdf，为“可以直接打开，但受到普通编辑或注释权限限制”的 PDF 生成新副本，方便在福昕阅读器中重新尝试“打字机”等注释功能。

## 下载和使用

普通用户请从 GitHub Releases 下载 `PDF权限处理工具_BAT版.zip`，完整解压后使用：

- 双击 `PDF权限处理工具.bat`，在窗口中一次选择一个或多个 PDF；或
- 在资源管理器中多选 PDF，拖到 `PDF权限处理工具.bat` 上。

输出保存在原文件所在目录，默认命名为 `原文件名_可注释.pdf`。如已存在，则自动使用 `_可注释_2.pdf`、`_可注释_3.pdf`，不会覆盖原文件。

详细说明见 [`src/使用说明.txt`](src/使用说明.txt)。

## 安全边界

- 仅处理用户有权修改的文件。
- 不猜测、不破解未知的打开密码。
- 不上传 PDF，不调用在线服务，不收集文件内容。
- 不修改或删除原文件。
- 重新生成的副本可能使数字签名或认证签名失效。
- 如果新文件仍无法使用福昕“打字机”，原因可能不是普通 PDF 权限限制。

## 技术结构

```text
src/
├─ PDF权限处理工具.bat   # 纯 ASCII、无 BOM 的入口
├─ tools/pdf_tool.ps1    # Windows PowerShell 5.1 处理逻辑
└─ 使用说明.txt
scripts/
├─ Fetch-Qpdf.ps1        # 固定版本和 SHA-256 的依赖获取
└─ Build-Portable.ps1    # 组装便携目录和 Release ZIP
tests/
├─ Run-Tests.ps1         # 单元、真实 qpdf 集成和 ZIP 验收
└─ Test-FetchIntegrity.ps1
```

BAT 内容保持纯 ASCII，不使用 `chcp 65001` 或延迟扩展；含中文的 PowerShell 脚本使用 UTF-8 BOM，以兼容 Windows PowerShell 5.1。

## 构建

在 Windows 10 x64、仓库根目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Portable.ps1
```

构建脚本会：

1. 下载 qpdf 12.4.2 官方 `msvc64` ZIP；
2. 校验固定 SHA-256；
3. 从校验后的 ZIP 清空重解压，验证精确版本；
4. 复制必要运行时和官方许可证；
5. 生成 `dist/PDF权限处理工具_BAT版/`、文件哈希清单和 Release ZIP。

## 测试

先运行上述构建命令，生成 `vendor/` 和 `dist/`，再执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -DeliverySmokeTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FetchIntegrity.ps1
```

测试覆盖普通 PDF、权限限制 PDF、需打开密码 PDF、损坏 PDF、qpdf 警告码、写入权限错误映射、同名递增、中文和 shell 特殊字符路径、原件不变、批次隔离、依赖篡改恢复、清单验证，以及从解压 ZIP 中实际运行 BAT。

## 第三方软件

便携包包含 qpdf 12.4.2 官方 Windows x64 运行时。qpdf 的 LICENSE、NOTICE 和版权信息随 Release 一并放在 `licenses/` 目录。qpdf 项目：https://github.com/qpdf/qpdf

## 发布

`dist/` 和 `vendor/` 不提交到 Git。发布者应从干净工作区运行构建与测试，然后把 `dist/PDF权限处理工具_BAT版.zip` 作为 GitHub Release 附件上传。
