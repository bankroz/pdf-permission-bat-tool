"""Remove only explicitly marked /Artifact /Watermark page content blocks."""

import argparse
import json
from pathlib import Path
import sys

from pypdf import PdfReader, PdfWriter
from pypdf.errors import PdfReadError
from pypdf.generic import ContentStream, DecodedStreamObject, DictionaryObject, NameObject


VERSION = "0.2.0"
EXIT_CODES = {"success": 0, "unsupported": 10, "encrypted": 11, "invalid": 12, "failed": 13}


class WatermarkStructureError(ValueError):
    """A candidate watermark has no matching marked-content terminator."""


class WatermarkSafetyError(ValueError):
    """Removing a block could change the graphics state of retained content."""


def _is_watermark(operands, operator):
    if operator != b"BDC" or len(operands) != 2:
        return False
    tag, properties = operands
    if not isinstance(tag, NameObject) or tag != NameObject("/Artifact"):
        return False
    if not isinstance(properties, DictionaryObject):
        return False
    subtype = properties.get("/Subtype")
    # NameObject and TextStringObject both inherit str; equality alone is unsafe.
    return isinstance(subtype, NameObject) and subtype == NameObject("/Watermark")


def _is_graphics_state_isolated(operations):
    """Require one balanced outer q/Q pair enclosing every other operation."""
    if len(operations) < 2 or operations[0][1] != b"q" or operations[-1][1] != b"Q":
        return False
    depth = 0
    for index, (_, operator) in enumerate(operations):
        if operator == b"q":
            depth += 1
        elif operator == b"Q":
            depth -= 1
        if depth < 0 or (depth == 0 and index != len(operations) - 1):
            return False
    return depth == 0


def _remove_watermarks(operations):
    retained = []
    ranges = []
    depth = 0
    start = 0
    for index, (operands, operator) in enumerate(operations):
        if depth:
            if operator in (b"BDC", b"BMC"):
                depth += 1
            elif operator == b"EMC":
                depth -= 1
            if depth == 0:
                ranges.append((start, index))
        elif _is_watermark(operands, operator):
            depth = 1
            start = index
        else:
            retained.append((index, (operands, operator)))
    if depth:
        raise WatermarkStructureError("水印标记内容块缺少匹配的 EMC")
    # Decide against the final retained content, so adjacent tail watermark
    # blocks can all be removed even when their graphics state is not isolated.
    last_retained = retained[-1][0] if retained else -1
    for start, end in ranges:
        if end < last_retained and not _is_graphics_state_isolated(operations[start + 1:end]):
            raise WatermarkSafetyError("水印绘图状态未隔离，安全跳过")
    return [operation for _, operation in retained], len(ranges)


def process_pdf(input_path, output_path):
    """Return status/message/pages/removed_blocks; write only when blocks were removed."""
    pages = 0
    output_started = False
    output = Path(output_path)
    try:
        source_path = Path(input_path)
        with source_path.open("rb") as source:
            reader = PdfReader(source, strict=False)
            if reader.is_encrypted and reader.decrypt("") == 0:
                return {"status": "encrypted", "message": "PDF 需要打开密码", "pages": 0, "removed_blocks": 0}
            pages = len(reader.pages)
            # pypdf 6.10.2 __enter__ reinitializes the writer, losing cloned pages.
            writer = PdfWriter(clone_from=reader)
            writer.pdf_header = reader.pdf_header
            removed_blocks = 0
            for page in writer.pages:
                contents = page.get_contents()
                if contents is None:
                    continue
                stream = ContentStream(contents, writer)
                retained, removed = _remove_watermarks(stream.operations)
                if removed:
                    stream.operations = retained
                    # Old content objects may be shared by other pages. Replace
                    # this page's reference without changing any shared object.
                    replacement = DecodedStreamObject()
                    replacement.set_data(stream.get_data())
                    page[NameObject("/Contents")] = writer._add_object(replacement.flate_encode())
                    removed_blocks += removed
            if not removed_blocks:
                return {"status": "unsupported", "message": "未找到明确标记的水印块", "pages": pages, "removed_blocks": 0}
            if source_path.resolve() == output.resolve() or (
                output.exists() and source_path.samefile(output)
            ):
                raise ValueError("输入与输出不能是同一文件")
            if output.exists():
                raise FileExistsError("输出文件已存在")
            with output.open("xb") as destination:
                output_started = True
                writer.write(destination)
        return {"status": "success", "message": "已删除明确标记的水印块", "pages": pages, "removed_blocks": removed_blocks}
    except WatermarkSafetyError as exc:
        status, message = "unsupported", str(exc)
    except (PdfReadError, WatermarkStructureError) as exc:
        status, message = "invalid", f"PDF 结构无效：{exc}"
    except Exception as exc:
        status, message = "failed", f"处理失败：{exc}"
    if output_started:
        try:
            output.unlink(missing_ok=True)
        except OSError as exc:
            message += f"；无法清理部分输出：{exc}"
    return {"status": status, "message": message, "pages": pages, "removed_blocks": 0}


def main(argv=None):
    parser = argparse.ArgumentParser(description="删除明确以 /Artifact /Watermark 标记的 PDF 水印块")
    parser.add_argument("--version", action="version", version=VERSION)
    parser.add_argument("input", help="输入 PDF")
    parser.add_argument("output", help="输出 PDF")
    args = parser.parse_args(argv)
    result = process_pdf(args.input, args.output)
    payload = json.dumps(result, ensure_ascii=False) + "\n"
    sys.stdout.buffer.write(payload.encode("utf-8"))
    sys.stdout.buffer.flush()
    return EXIT_CODES[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
