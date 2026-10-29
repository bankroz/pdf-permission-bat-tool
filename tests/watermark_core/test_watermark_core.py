"""Generated, non-confidential PDFs exercise the public core and CLI."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from pypdf import PdfReader, PdfWriter
from pypdf.generic import ContentStream, DecodedStreamObject, NameObject


ROOT = Path(__file__).resolve().parents[2]
CORE_PATH = ROOT / "src" / "watermark_core" / "watermark_core.py"
sys.path.insert(0, str(CORE_PATH.parent))
try:
    import watermark_core
except ModuleNotFoundError as exc:
    if exc.name != "watermark_core":
        raise
    watermark_core = None

BODY = b"q 0 0 1 rg 10 10 40 40 re f Q\n"
MARK = b"q 1 0 0 rg 20 20 10 10 re f Q\n"
START = b"/Artifact << /Subtype /Watermark /Type /Pagination >> BDC\n"
WATERMARK = START + MARK + b"EMC\n"


class WatermarkCoreTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(watermark_core, "watermark_core implementation is missing")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.input = Path(self.temp.name) / "输入.pdf"
        self.output = Path(self.temp.name) / "输出.pdf"

    def make_pdf(self, *pages, password=None):
        writer = PdfWriter()
        for data in pages:
            page = writer.add_blank_page(width=100, height=100)
            stream = DecodedStreamObject()
            stream.set_data(data)
            page[NameObject("/Contents")] = writer._add_object(stream)
        if password is not None:
            writer.encrypt(password, owner_password="owner-secret")
        writer.write(self.input)

    def operations(self, data):
        stream = DecodedStreamObject()
        stream.set_data(data)
        return ContentStream(stream, None).operations

    def output_operations(self, page_number=0):
        reader = PdfReader(self.output)
        return ContentStream(reader.pages[page_number].get_contents(), reader).operations

    def process(self):
        result = watermark_core.process_pdf(self.input, self.output)
        self.assertEqual(set(result), {"status", "message", "pages", "removed_blocks"})
        self.assertIsInstance(result["message"], str)
        self.assertTrue(result["message"])
        return result

    def assert_no_output(self, status):
        result = self.process()
        self.assertEqual(result["status"], status)
        self.assertFalse(self.output.exists())
        return result

    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, str(CORE_PATH), *map(str, args)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def test_removes_one_watermark_and_preserves_body_operations(self):
        self.make_pdf(WATERMARK + BODY)
        result = self.process()
        self.assertEqual(result["status"], "success")
        self.assertEqual((result["pages"], result["removed_blocks"]), (1, 1))
        self.assertEqual(self.output_operations(), self.operations(BODY))
        self.assertEqual(PdfReader(self.input).pages[0].get_contents().get_data(), WATERMARK + BODY)

    def test_counts_three_watermarks_across_two_pages(self):
        self.make_pdf(WATERMARK + BODY, BODY + WATERMARK + WATERMARK)
        result = self.process()
        self.assertEqual(result["status"], "success")
        self.assertEqual((result["pages"], result["removed_blocks"]), (2, 3))
        self.assertEqual(len(PdfReader(self.output).pages), 2)
        for page in range(2):
            self.assertEqual(self.output_operations(page), self.operations(BODY))

    def test_preserves_header_artifact(self):
        header = b"/Artifact << /Subtype /Header >> BDC\n" + MARK + b"EMC\n"
        self.make_pdf(header + WATERMARK + BODY)
        self.assertEqual(self.process()["removed_blocks"], 1)
        self.assertEqual(self.output_operations(), self.operations(header + BODY))

    def test_preserves_span_mcid(self):
        span = b"/Span << /MCID 0 >> BDC\n" + MARK + b"EMC\n"
        self.make_pdf(WATERMARK + span + BODY)
        self.assertEqual(self.process()["removed_blocks"], 1)
        self.assertEqual(self.output_operations(), self.operations(span + BODY))

    def test_removes_nested_bdc_and_bmc_as_one_outer_block(self):
        nested = b"/Span << /MCID 0 >> BDC\n/Span BMC\n" + MARK + b"EMC\nEMC\n"
        self.make_pdf(START + nested + b"EMC\n" + BODY)
        self.assertEqual(self.process()["removed_blocks"], 1)
        self.assertEqual(self.output_operations(), self.operations(BODY))

    def test_preserves_parent_marked_content_around_watermark(self):
        prefix = b"/Span << /MCID 0 >> BDC\n"
        suffix = b"EMC\n"
        self.make_pdf(prefix + WATERMARK + BODY + suffix)
        self.assertEqual(self.process()["removed_blocks"], 1)
        self.assertEqual(self.output_operations(), self.operations(prefix + BODY + suffix))

    def test_no_watermark_is_unsupported_without_output(self):
        self.make_pdf(BODY)
        result = self.assert_no_output("unsupported")
        self.assertEqual((result["pages"], result["removed_blocks"]), (1, 0))

    def test_only_exact_name_tag_and_inline_dictionary_are_candidates(self):
        for marker in (
            b"/Artifact /WM BDC\n",
            b"/Span << /Subtype /Watermark >> BDC\n",
            b"(/Artifact) << /Subtype /Watermark >> BDC\n",
            b"/Artifact << /Subtype (/Watermark) >> BDC\n",
            b"/Artifact << /Subtype /WatermarkExtra >> BDC\n",
            b"/Artifact << /Subtype /Watermark >> 0 BDC\n",
        ):
            with self.subTest(marker=marker):
                self.make_pdf(marker + MARK + b"EMC\n" + BODY)
                self.assert_no_output("unsupported")

    def test_unclosed_watermark_is_invalid_without_output(self):
        self.make_pdf(START + MARK + BODY)
        self.assert_no_output("invalid")

    def test_nested_unclosed_watermark_is_invalid_without_output(self):
        self.make_pdf(START + b"/Span BMC\n" + MARK + b"EMC\n" + BODY)
        self.assert_no_output("invalid")

    def test_later_invalid_page_prevents_partial_output(self):
        self.make_pdf(WATERMARK + BODY, START + MARK)
        self.assert_no_output("invalid")

    def test_open_password_is_encrypted_without_output(self):
        self.make_pdf(WATERMARK + BODY, password="user-secret")
        self.assert_no_output("encrypted")

    def test_empty_user_password_can_be_processed(self):
        self.make_pdf(WATERMARK + BODY, password="")
        self.assertEqual(self.process()["status"], "success")
        self.assertEqual(self.output_operations(), self.operations(BODY))

    def test_invalid_pdf_is_invalid_without_output(self):
        self.input.write_bytes(b"%PDF-1.7\nnot a PDF\n%%EOF\n")
        self.assert_no_output("invalid")

    def test_output_io_failure_returns_failed(self):
        self.make_pdf(WATERMARK + BODY)
        self.output = self.output.parent / "missing-directory" / "out.pdf"
        self.assert_no_output("failed")

    def test_same_input_and_output_is_rejected_without_changing_input(self):
        self.make_pdf(WATERMARK + BODY)
        original = self.input.read_bytes()
        self.output = self.input
        self.assertEqual(self.process()["status"], "failed")
        self.assertEqual(self.input.read_bytes(), original)

    def test_partial_output_is_removed_after_write_failure(self):
        self.make_pdf(WATERMARK + BODY)

        def interrupted_write(writer, destination):
            destination.write(b"%PDF-1.7\npartial output")
            raise OSError("simulated interrupted write")

        # Inject a disk failure after real bytes are written; the filesystem and
        # processing stay real, without relying on platform-specific disk limits.
        with patch.object(PdfWriter, "write", interrupted_write):
            self.assert_no_output("failed")

    def test_cli_returns_utf8_json_and_success_exit_code(self):
        self.make_pdf(WATERMARK + BODY)
        completed = self.run_cli(self.input, self.output)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout.decode("utf-8"))
        self.assertEqual(set(result), {"status", "message", "pages", "removed_blocks"})
        self.assertEqual(result["status"], "success")
        self.assertNotIn(b"\\u", completed.stdout)
        self.assertEqual(self.output_operations(), self.operations(BODY))

    def test_cli_stable_error_exit_codes(self):
        cases = ((BODY, None, "unsupported", 10),
                 (WATERMARK, "secret", "encrypted", 11),
                 (START + MARK, None, "invalid", 12))
        for data, password, status, code in cases:
            with self.subTest(status=status):
                self.make_pdf(data, password=password)
                completed = self.run_cli(self.input, self.output)
                self.assertEqual(completed.returncode, code, completed.stderr)
                self.assertEqual(json.loads(completed.stdout.decode("utf-8"))["status"], status)
                self.assertFalse(self.output.exists())
        self.make_pdf(WATERMARK)
        self.output = self.output.parent / "missing" / "out.pdf"
        completed = self.run_cli(self.input, self.output)
        self.assertEqual(completed.returncode, 13, completed.stderr)
        self.assertEqual(json.loads(completed.stdout.decode("utf-8"))["status"], "failed")

    def test_version_is_0_2_0(self):
        self.assertEqual(watermark_core.VERSION, "0.2.0")
        completed = self.run_cli("--version")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.decode("utf-8").strip(), "0.2.0")


if __name__ == "__main__":
    unittest.main()
