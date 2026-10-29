# Structured PDF Watermark Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Add a separate Windows 10 x64 portable BAT tool that batch-removes only PDF content blocks explicitly marked as /Artifact with /Subtype /Watermark, without overwriting source files.

**Architecture:** A pure-ASCII BAT launcher invokes a Windows PowerShell 5.1 orchestration script. The script calls a PyInstaller-built Python 3.10 executable using pypdf to parse and rewrite content-stream operators, then uses the already bundled qpdf 12.4.2 to validate the temporary result before publishing it beside the input file.

**Tech Stack:** Windows batch, Windows PowerShell 5.1, Python 3.10, pypdf 6.10.2, PyInstaller 6.20.0, qpdf 12.4.2, Python unittest.

---

## File map

- Create src/PDF去水印工具.bat: ASCII launcher.
- Create src/tools/watermark_ui.ps1: selection, batch isolation, naming, validation, and summaries.
- Create src/watermark_core/watermark_core.py: strict detector, content-stream rewriter, and JSON CLI.
- Create tests/watermark_core/test_watermark_core.py: generated-fixture core tests.
- Create tests/Run-WatermarkTests.ps1: PowerShell and packaged-BAT tests.
- Create scripts/requirements-watermark-build.txt: pinned direct dependencies.
- Create scripts/Build-WatermarkCore.ps1: isolated Python 3.10 EXE build.
- Create third_party/pypdf-LICENSE.txt and third_party/PyInstaller-COPYING.txt.
- Modify .gitignore, scripts/Build-Portable.ps1, tests/Run-Tests.ps1, src/使用说明.txt, and README.md.

### Task 1: Implement the strict core with TDD

**Files:**

- Create: tests/watermark_core/test_watermark_core.py
- Create: src/watermark_core/watermark_core.py

- [ ] **Step 1: Write failing generated-fixture tests**

Create a unittest module that never uses or copies the confidential sample. Its fixture helper must construct page streams with pypdf:

    BODY = b"q 0 0 1 rg 10 10 40 40 re f Q\n"
    WATERMARK = (
        b"/Artifact << /Subtype /Watermark /Type /Pagination >> BDC\n"
        b"q 1 0 0 rg 20 20 50 10 re f Q\n"
        b"EMC\n"
    )

    def write_fixture(path, page_streams, encrypt_password=None):
        writer = PdfWriter()
        for data in page_streams:
            page = writer.add_blank_page(width=200, height=200)
            stream = DecodedStreamObject()
            stream.set_data(data)
            page[NameObject("/Contents")] = writer._add_object(stream)
        if encrypt_password is not None:
            writer.encrypt(user_password=encrypt_password, owner_password="owner-secret")
        with path.open("wb") as handle:
            writer.write(handle)

Add these exact behavioral tests:

- WATERMARK + BODY removes one block and retains rectangle operations.
- Two pages with three total watermark blocks report pages=2 and removed_blocks=3.
- /Artifact with /Subtype /Header remains.
- /Span with /MCID remains.
- A nested BDC/EMC inside a watermark block is removed with its outer watermark.
- A plain PDF returns unsupported and creates no output.
- An unclosed watermark BDC returns invalid and creates no output.
- A password-encrypted PDF returns encrypted and creates no output.
- The CLI emits UTF-8 JSON and exit code 0 for success.

Representative assertions:

    result = process_pdf(source, output)
    self.assertEqual("success", result["status"])
    self.assertEqual(1, result["removed_blocks"])
    self.assertTrue(output.is_file())

    operations = ContentStream(
        PdfReader(output).pages[0].get_contents(),
        PdfReader(output),
    ).operations
    self.assertFalse(
        any(
            operator == b"BDC"
            and operands[0] == NameObject("/Artifact")
            and operands[1].get(NameObject("/Subtype")) == NameObject("/Watermark")
            for operands, operator in operations
        )
    )

- [ ] **Step 2: Run the tests and verify the absent-core failure**

Run:

    python -m unittest discover -s tests/watermark_core -v

Expected: FAIL with ModuleNotFoundError for watermark_core.

- [ ] **Step 3: Implement the parser, rewriter, and JSON CLI**

Create src/watermark_core/watermark_core.py with these complete core contracts:

    from __future__ import annotations

    import argparse
    import json
    import sys
    from pathlib import Path
    from typing import Any

    from pypdf import PdfReader, PdfWriter
    from pypdf.errors import PdfReadError
    from pypdf.generic import ContentStream, DictionaryObject, NameObject

    VERSION = "0.2.0"
    EXIT_CODES = {
        "success": 0,
        "unsupported": 10,
        "encrypted": 11,
        "invalid": 12,
        "failed": 13,
    }


    class WatermarkStructureError(ValueError):
        pass


    def result(status, message, pages=0, removed_blocks=0):
        return {
            "status": status,
            "message": message,
            "pages": pages,
            "removed_blocks": removed_blocks,
        }


    def is_watermark_start(operands: list[Any], operator: bytes) -> bool:
        if operator != b"BDC" or len(operands) != 2:
            return False
        tag, properties = operands
        return (
            tag == NameObject("/Artifact")
            and isinstance(properties, DictionaryObject)
            and properties.get(NameObject("/Subtype")) == NameObject("/Watermark")
        )


    def remove_watermark_operations(operations):
        kept = []
        skip_depth = 0
        removed = 0
        for operands, operator in operations:
            if skip_depth:
                if operator in (b"BDC", b"BMC"):
                    skip_depth += 1
                elif operator == b"EMC":
                    skip_depth -= 1
                continue
            if is_watermark_start(operands, operator):
                skip_depth = 1
                removed += 1
                continue
            kept.append((operands, operator))
        if skip_depth:
            raise WatermarkStructureError("水印标记内容块未正确闭合。")
        return kept, removed


    def remove_partial_output(path: Path) -> None:
        try:
            if path.is_file():
                path.unlink()
        except OSError:
            pass


    def process_pdf(input_path, output_path):
        source = Path(input_path)
        output = Path(output_path)
        remove_partial_output(output)
        pages = 0
        try:
            reader = PdfReader(source, strict=False)
            if reader.is_encrypted and reader.decrypt("") == 0:
                return result("encrypted", "文件需要打开密码，未处理。")
            pages = len(reader.pages)
            removed_total = 0
            for page in reader.pages:
                contents = page.get_contents()
                if contents is None:
                    continue
                parsed = ContentStream(contents, reader)
                kept, removed = remove_watermark_operations(parsed.operations)
                if removed:
                    parsed.operations = kept
                    page.replace_contents(parsed)
                    removed_total += removed
            if removed_total == 0:
                return result("unsupported", "未发现支持的结构化水印。", pages)
            output.parent.mkdir(parents=True, exist_ok=True)
            writer = PdfWriter(clone_from=reader)
            with output.open("wb") as handle:
                writer.write(handle)
            if not output.is_file() or output.stat().st_size == 0:
                raise OSError("核心未生成有效输出文件。")
            return result("success", "已删除结构化水印。", pages, removed_total)
        except WatermarkStructureError as error:
            remove_partial_output(output)
            return result("invalid", str(error), pages)
        except (PdfReadError, EOFError, ValueError) as error:
            remove_partial_output(output)
            return result("invalid", "PDF 无法解析：" + str(error), pages)
        except Exception as error:
            remove_partial_output(output)
            return result("failed", "处理失败：" + str(error), pages)


    def main(argv=None):
        parser = argparse.ArgumentParser()
        parser.add_argument("--version", action="version", version=VERSION)
        parser.add_argument("input")
        parser.add_argument("output")
        arguments = parser.parse_args(argv)
        payload = process_pdf(arguments.input, arguments.output)
        encoded = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
        sys.stdout.buffer.write(encoded)
        return EXIT_CODES[payload["status"]]


    if __name__ == "__main__":
        raise SystemExit(main())

- [ ] **Step 4: Run the core tests**

Run:

    python -m unittest discover -s tests/watermark_core -v

Expected: all nine tests PASS.

- [ ] **Step 5: Commit**

    git add src/watermark_core/watermark_core.py tests/watermark_core/test_watermark_core.py
    git commit -m "feat: remove explicitly marked PDF watermarks"

### Task 2: Add the BAT and PowerShell batch boundary

**Files:**

- Create: src/PDF去水印工具.bat
- Create: src/tools/watermark_ui.ps1
- Create: tests/Run-WatermarkTests.ps1

- [ ] **Step 1: Write failing launcher and library contract tests**

The test script must dot-source watermark_ui.ps1 with LibraryMode and assert:

    Get-WatermarkOutputPath "中文 & 文件!.pdf"
    # first result ends with 中文 & 文件!_去水印.pdf

    # after creating that result:
    Get-WatermarkOutputPath "中文 & 文件!.pdf"
    # second result ends with 中文 & 文件!_去水印_2.pdf

It must also assert the BAT exists, contains only bytes below 0x80, has no BOM, does not call chcp, and does not enable delayed expansion. Invoke-WatermarkMain with missing explicit core and qpdf paths must return 2.

Run:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-WatermarkTests.ps1

Expected: FAIL because the new launcher and UI do not exist.

- [ ] **Step 2: Create the ASCII launcher**

Create src/PDF去水印工具.bat with CRLF and no BOM:

    @echo off
    setlocal DisableDelayedExpansion
    set "TOOL_ROOT=%~dp0"
    powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%TOOL_ROOT%tools\watermark_ui.ps1" %*
    set "TOOL_EXIT=%ERRORLEVEL%"
    echo(
    pause
    exit /b %TOOL_EXIT%

- [ ] **Step 3: Implement focused PowerShell functions**

Create src/tools/watermark_ui.ps1 as UTF-8 with BOM and the same parameter pattern as pdf_tool.ps1:

    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$InputFiles,
        [switch]$LibraryMode,
        [switch]$NoPrompt,
        [string]$CorePath,
        [string]$QpdfPath
    )

Implement these exact functions:

- New-WatermarkResult with Valid, Success, Warning, Failed, and Skipped statuses.
- Test-WatermarkInputPath accepting only existing .pdf files.
- Get-WatermarkOutputPath using _去水印 and numbered collisions.
- Select-WatermarkPdfFiles with a multiselect Windows Forms dialog.
- Confirm-WatermarkProcessing with authorization, non-overwrite, and signature warnings.
- Resolve-WatermarkDependencies defaulting to watermark/watermark_core.exe and qpdf/bin/qpdf.exe below the delivery root.
- Test-WatermarkDependencies requiring core version 0.2.0 and qpdf version 12.4.2.
- Invoke-WatermarkCore capturing combined output, parsing UTF-8 JSON, and mapping exit/status fields.
- Test-WatermarkOutput running qpdf --check and --show-npages; only check exits 0 and 3 are acceptable.
- Invoke-WatermarkFile creating a unique .watermark.tmp.pdf beside the input, publishing only validated core success, mapping unsupported to Skipped, and cleaning temp files in finally.
- Show-WatermarkResult and Show-WatermarkSummary.
- Invoke-WatermarkMain isolating each file in its own try/catch; return 1 for any Failed result, 2 for dependency failure, otherwise 0.

The JSON mapping must be:

    [pscustomobject]@{
        ExitCode = $exitCode
        Status = [string]$payload.status
        Message = [string]$payload.message
        Pages = [int]$payload.pages
        RemovedBlocks = [int]$payload.removed_blocks
        Details = $rawText
    }

The final executable boundary must be:

    if (-not $LibraryMode) {
        $exitCode = Invoke-WatermarkMain -InputFiles $InputFiles -NoPrompt:$NoPrompt -CorePath $CorePath -QpdfPath $QpdfPath
        exit $exitCode
    }

- [ ] **Step 4: Expand PowerShell tests with deterministic fake executables**

Use fake CMD files with these behaviors:

Success core:

    @echo off
    copy /b "%~1" "%~2" >nul
    echo {"status":"success","message":"ok","pages":1,"removed_blocks":1}
    exit /b 0

Unsupported core:

    @echo off
    echo {"status":"unsupported","message":"unsupported","pages":1,"removed_blocks":0}
    exit /b 10

Validation qpdf:

    @echo off
    if "%~1"=="--version" echo qpdf version 12.4.2& exit /b 0
    if "%~1"=="--check" exit /b 0
    if "%~1"=="--show-npages" echo 1& exit /b 0
    exit /b 2

Assert success publishes one output, unsupported publishes none, a failing qpdf check publishes none, mixed batches continue, input SHA-256 and timestamp stay unchanged, and no .watermark.tmp.pdf remains.

- [ ] **Step 5: Run all new tests and commit**

    python -m unittest discover -s tests/watermark_core -v
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-WatermarkTests.ps1

Expected: both suites PASS.

    git add src/PDF去水印工具.bat src/tools/watermark_ui.ps1 tests/Run-WatermarkTests.ps1
    git commit -m "feat: add portable watermark removal launcher"

### Task 3: Build the standalone Windows core

**Files:**

- Create: scripts/requirements-watermark-build.txt
- Create: scripts/Build-WatermarkCore.ps1
- Create: third_party/pypdf-LICENSE.txt
- Create: third_party/PyInstaller-COPYING.txt
- Modify: .gitignore

- [ ] **Step 1: Pin dependencies and ignore build artifacts**

requirements-watermark-build.txt:

    pypdf==6.10.2
    PyInstaller==6.20.0

Append:

    .build/
    *_去水印.pdf

- [ ] **Step 2: Add exact upstream license texts**

Copy the unmodified pypdf 6.10.2 LICENSE and PyInstaller 6.20.0 COPYING.txt from their installed distributions. Verify pypdf states BSD-3-Clause and PyInstaller includes its bootloader exception.

- [ ] **Step 3: Implement Build-WatermarkCore.ps1**

The script must:

1. Resolve .build/watermark-core and verify it is below the repository .build directory before recursive cleanup.
2. Run py -3.10 -m venv .build/watermark-core/venv.
3. Install scripts/requirements-watermark-build.txt with pip.
4. Invoke PyInstaller with --onefile, --console, --name watermark_core, and explicit dist/work/spec paths below .build.
5. Run the result with --version and require exactly 0.2.0.
6. Output the absolute EXE path as its final pipeline item.

Core build command:

    & $python -m PyInstaller --noconfirm --clean --onefile --console --name watermark_core --distpath $dist --workpath $work --specpath $spec (Join-Path $projectRoot 'src\watermark_core\watermark_core.py')

- [ ] **Step 4: Build and verify**

    $exe = & .\scripts\Build-WatermarkCore.ps1 | Select-Object -Last 1
    & $exe --version

Expected: 0.2.0 and a nonempty .build/watermark-core/dist/watermark_core.exe.

- [ ] **Step 5: Commit**

    git add .gitignore scripts/requirements-watermark-build.txt scripts/Build-WatermarkCore.ps1 third_party
    git commit -m "build: package standalone watermark core"

### Task 4: Integrate the portable distribution

**Files:**

- Modify: scripts/Build-Portable.ps1
- Modify: tests/Run-Tests.ps1
- Modify: tests/Run-WatermarkTests.ps1

- [ ] **Step 1: Add failing delivery assertions**

With DeliverySmokeTest, require:

    PDF去水印工具.bat
    tools\watermark_ui.ps1
    watermark\watermark_core.exe
    licenses\pypdf-LICENSE.txt
    licenses\PyInstaller-COPYING.txt

Run the watermark delivery test and expect FAIL before packaging changes.

- [ ] **Step 2: Package the new files**

Before SHA256SUMS.txt is generated, Build-Portable.ps1 must:

    $watermarkCore = & (Join-Path $PSScriptRoot 'Build-WatermarkCore.ps1') | Select-Object -Last 1
    $watermarkDir = Join-Path $delivery 'watermark'
    New-Item -ItemType Directory -Force -Path $watermarkDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'src\PDF去水印工具.bat') -Destination $delivery
    Copy-Item -LiteralPath (Join-Path $projectRoot 'src\tools\watermark_ui.ps1') -Destination $toolsDir
    Copy-Item -LiteralPath $watermarkCore -Destination (Join-Path $watermarkDir 'watermark_core.exe')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'third_party\pypdf-LICENSE.txt') -Destination $licensesDir
    Copy-Item -LiteralPath (Join-Path $projectRoot 'third_party\PyInstaller-COPYING.txt') -Destination $licensesDir

Also run packaged watermark_core.exe --version and require 0.2.0 before manifest generation.

- [ ] **Step 3: Add extracted-ZIP acceptance**

Generate a one-page marked fixture with the Python test helper. Extract the ZIP into a path containing Chinese, spaces, ampersand, exclamation mark, and parentheses. Run PDF去水印工具.bat -NoPrompt on the fixture. Require exit 0, exactly one _去水印.pdf output, qpdf --check success, one page, and no temporary file.

- [ ] **Step 4: Run packaging and all tests**

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Portable.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -DeliverySmokeTest
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-WatermarkTests.ps1 -DeliverySmokeTest
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FetchIntegrity.ps1

Expected: all old and new tests PASS.

- [ ] **Step 5: Commit**

    git add scripts/Build-Portable.ps1 tests/Run-Tests.ps1 tests/Run-WatermarkTests.ps1
    git commit -m "build: include watermark remover in portable release"

### Task 5: Document the product boundary

**Files:**

- Modify: README.md
- Modify: src/使用说明.txt

- [ ] **Step 1: Document exact behavior**

Both documents must state:

    PDF去水印工具.bat 只清除明确标记为 /Artifact 且 /Subtype 为 /Watermark 的结构化水印。
    它不根据颜色、角度或重复文字猜测水印，也不处理扫描图片水印。
    成功输出为“原文件名_去水印.pdf”，重名时自动递增，永不覆盖原文件。
    未识别到支持的结构化水印时跳过，不生成副本。
    处理可能使数字签名失效；仅用于你有权修改的文件。
    所有处理均在本机完成，不上传 PDF。

Update the file tree, build command, tests, dependencies, and license section.

- [ ] **Step 2: Check claims and formatting**

    git diff --check
    rg -n "万能|所有水印|扫描水印" README.md src/使用说明.txt

Expected: no whitespace errors and no universal-removal claim.

- [ ] **Step 3: Commit**

    git add README.md src/使用说明.txt
    git commit -m "docs: explain structured watermark removal"

### Task 6: Validate the user's confidential sample without committing it

**Runtime files only:**

- Input: C:\Work\Drive\WorXlab\Project\软件移植\E-2978 AQI List of attachments\E-2978_AQI_compact_Funktionstest_report_2_可注释.pdf
- Expected sibling output: E-2978_AQI_compact_Funktionstest_report_2_可注释_去水印.pdf

- [ ] **Step 1: Record immutable source facts**

Record SHA-256, size, page count, and LastWriteTimeUtc. Resolve the exact expected sibling output. Only remove that output first if it is a prior generated test artifact. Never remove or rename the input.

- [ ] **Step 2: Run the packaged BAT**

    $bat = 'C:\Work\Drive\MCBASE\AI人工智能\软件\PDF权限处理工具_BAT版\dist\PDF权限处理工具_BAT版\PDF去水印工具.bat'
    '' | & $bat '-NoPrompt' $sample

Expected: exit 0, four pages, four removed blocks, and one sibling _去水印.pdf.

- [ ] **Step 3: Validate structure and preservation**

Run packaged qpdf --check and --show-npages. Require four pages. Recalculate source SHA-256 and LastWriteTimeUtc and require exact equality. Extract text from input and output; require both watermark phrases to disappear from output while known body headings remain.

- [ ] **Step 4: Render and visually inspect**

Render output pages 1 and 4 at 150 DPI with pdftoppm and inspect both PNGs. Require the diagonal red watermark to be absent and tables, headings, page geometry, and annotations to show no obvious loss.

- [ ] **Step 5: Run final regression and inspect Git state**

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -DeliverySmokeTest
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-WatermarkTests.ps1 -DeliverySmokeTest
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FetchIntegrity.ps1
    git diff --check
    git status --short --branch

Expected: all tests PASS. The confidential input, generated output, tmp, .build, dist, and virtual environment are not staged.

- [ ] **Step 6: Commit only real tracked corrections**

If sample validation exposed a tracked defect, add only the exact source or test files that fix it and commit with:

    git commit -m "test: verify structured watermark removal end to end"

Do not create an empty commit.

## Self-review results

- Spec coverage: detection, nested blocks, unsupported files, batch isolation, original preservation, qpdf validation, portable packaging, licenses, documentation, and sample acceptance all map to tasks.
- Placeholder scan: every implementation and validation step is concrete; no deferred work marker remains.
- Type consistency: JSON keys are status, message, pages, and removed_blocks throughout; final filenames consistently use _去水印.

