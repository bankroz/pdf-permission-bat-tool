"""Generated, non-confidential PDFs exercise the public core and CLI."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from pypdf import PdfReader, PdfWriter
from pypdf.generic import (
    ArrayObject, ContentStream, DecodedStreamObject, DictionaryObject, FloatObject,
    NameObject,
)


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
# A real one-pixel inline image avoids text/path effects in middle-block fixtures.
MARK = b"q 20 0 0 20 20 20 cm BI /W 1 /H 1 /CS /RGB /BPC 8 ID \xff\x00\x00 EI Q\n"
START = b"/Artifact << /Subtype /Watermark /Type /Pagination >> BDC\n"
WATERMARK = START + MARK + b"EMC\n"
GRAPHICS_STATE = b"0.5 g 0.5 G /GS0 gs\n"
STATE_RESOURCES = DictionaryObject({
    NameObject("/ExtGState"): DictionaryObject({
        NameObject("/GS0"): DictionaryObject({
            NameObject("/Type"): NameObject("/ExtGState"),
            NameObject("/ca"): FloatObject(0.5),
        }),
    }),
})


class WatermarkCoreTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(watermark_core, "watermark_core implementation is missing")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.input = Path(self.temp.name) / "输入.pdf"
        self.output = Path(self.temp.name) / "输出.pdf"

    def make_pdf(self, *pages, password=None, pdf_header=None, resources=None):
        writer = PdfWriter()
        if pdf_header is not None:
            writer.pdf_header = pdf_header
        for data in pages:
            page = writer.add_blank_page(width=100, height=100)
            if resources is not None:
                page[NameObject("/Resources")] = resources
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

    def test_preserves_input_pdf_header(self):
        for header in ("%PDF-1.5", "%PDF-1.7"):
            with self.subTest(header=header):
                self.output = self.output.with_name(f"output-{header[-3:]}.pdf")
                self.make_pdf(WATERMARK + BODY, pdf_header=header)
                self.assertEqual(self.process()["status"], "success")
                self.assertEqual(PdfReader(self.input).pdf_header, header)
                self.assertEqual(PdfReader(self.output).pdf_header, header)
                self.assertEqual(
                    self.output.read_bytes().splitlines()[0],
                    self.input.read_bytes().splitlines()[0],
                )

    def test_modified_content_stream_is_losslessly_flate_encoded(self):
        self.make_pdf(WATERMARK + BODY * 32)
        self.assertEqual(self.process()["status"], "success")
        contents = PdfReader(self.output).pages[0]["/Contents"]
        self.assertEqual(contents.get("/Filter"), NameObject("/FlateDecode"))
        self.assertEqual(self.output_operations(), self.operations(BODY * 32))

    def test_graphics_state_before_q_and_following_body_is_unsupported(self):
        unsafe = START + GRAPHICS_STATE + MARK + b"EMC\n"
        self.make_pdf(unsafe + BODY, resources=STATE_RESOURCES)
        result = self.assert_no_output("unsupported")
        self.assertEqual(result["message"], "水印绘图状态未隔离，安全跳过")
        self.assertEqual((result["pages"], result["removed_blocks"]), (1, 0))

    def test_graphics_state_inside_outer_q_is_safe_with_following_body(self):
        isolated = START + b"q\n" + GRAPHICS_STATE + MARK + b"Q\nEMC\n"
        self.make_pdf(isolated + BODY, resources=STATE_RESOURCES)
        result = self.process()
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["removed_blocks"], 1)
        self.assertEqual(self.output_operations(), self.operations(BODY))

    def test_two_nonisolated_tail_blocks_can_both_be_removed(self):
        unsafe = START + GRAPHICS_STATE + MARK + b"EMC\n"
        self.make_pdf(BODY + unsafe + unsafe, resources=STATE_RESOURCES)
        result = self.process()
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["removed_blocks"], 2)
        self.assertEqual(self.output_operations(), self.operations(BODY))

    def test_nonisolated_tail_block_followed_only_by_isolated_block_is_safe(self):
        unsafe = START + GRAPHICS_STATE + MARK + b"EMC\n"
        self.make_pdf(BODY + unsafe + WATERMARK, resources=STATE_RESOURCES)
        result = self.process()
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["removed_blocks"], 2)
        self.assertEqual(self.output_operations(), self.operations(BODY))

    def test_unsafe_block_on_later_page_prevents_entire_output(self):
        unsafe = START + GRAPHICS_STATE + MARK + b"EMC\n"
        self.make_pdf(WATERMARK + BODY, unsafe + BODY, resources=STATE_RESOURCES)
        self.assert_no_output("unsupported")

    def test_unsafe_block_keeps_existing_output_and_unsupported_status(self):
        unsafe = START + GRAPHICS_STATE + MARK + b"EMC\n"
        self.make_pdf(unsafe + BODY, resources=STATE_RESOURCES)
        original = b"existing output survives safety rejection"
        self.output.write_bytes(original)
        result = self.process()
        self.assertEqual(result["status"], "unsupported")
        self.assertEqual(result["message"], "水印绘图状态未隔离，安全跳过")
        self.assertEqual(self.output.read_bytes(), original)

    def test_outer_q_must_enclose_all_content_and_have_balanced_depth(self):
        for index, inner in enumerate((
            b"", b"0.5 g\n", b"q Q q Q\n", b"q Q Q\n",
            b"q q Q\n", b"q Q 0.5 g\n", b"q Q 0.5 g q Q\n",
        )):
            with self.subTest(inner=inner):
                self.output = self.output.with_name(f"unsafe-{index}.pdf")
                self.make_pdf(START + inner + b"EMC\n" + BODY)
                self.assert_no_output("unsupported")

    def test_nonisolated_block_before_retained_markers_is_unsupported(self):
        self.make_pdf(START + GRAPHICS_STATE + b"EMC\n/Span BMC EMC\n",
                      resources=STATE_RESOURCES)
        self.assert_no_output("unsupported")

    def test_cli_safety_rejection_is_utf8_json_with_unsupported_exit_code(self):
        self.make_pdf(START + GRAPHICS_STATE + MARK + b"EMC\n" + BODY,
                      resources=STATE_RESOURCES)
        completed = self.run_cli(self.input, self.output)
        self.assertEqual(completed.returncode, 10, completed.stderr)
        result = json.loads(completed.stdout.decode("utf-8"))
        self.assertEqual(result["status"], "unsupported")
        self.assertEqual(result["message"], "水印绘图状态未隔离，安全跳过")
        self.assertFalse(self.output.exists())

    def test_review_text_matrix_change_is_rejected_without_changing_source(self):
        content = (b"BT\n" + START + b"q 20 0 Td (WM) Tj Q\nEMC\n"
                   + b"(BODY) Tj ET\n")
        self.make_pdf(content)
        original = self.input.read_bytes()
        self.assert_no_output("unsupported")
        self.assertEqual(self.input.read_bytes(), original)
        self.assertEqual(PdfReader(self.input).pages[0].get_contents().get_data(), content)

    def test_review_path_consumption_is_rejected_without_changing_source(self):
        content = b"10 10 40 40 re\n" + START + b"q n Q\nEMC\nf\n"
        self.make_pdf(content)
        original = self.input.read_bytes()
        self.assert_no_output("unsupported")
        self.assertEqual(self.input.read_bytes(), original)
        self.assertEqual(PdfReader(self.input).pages[0].get_contents().get_data(), content)

    def test_compatibility_scope_crossing_candidate_boundary_is_rejected(self):
        for index, (prefix, inner, suffix) in enumerate((
            (b"BX\n", b"EX\n", BODY),
            (b"", b"BX\n", BODY + b"EX\n"),
        )):
            with self.subTest(inner=inner):
                self.output = self.output.with_name(f"compatibility-{index}.pdf")
                content = prefix + START + b"q\n" + inner + b"Q\nEMC\n" + suffix
                self.make_pdf(content)
                original = self.input.read_bytes()
                self.assert_no_output("unsupported")
                self.assertEqual(self.input.read_bytes(), original)
                self.assertEqual(PdfReader(self.input).pages[0].get_contents().get_data(), content)

    def test_external_text_object_rejects_an_otherwise_safe_middle_block(self):
        self.make_pdf(b"BT\n" + WATERMARK + b"(BODY) Tj ET\n")
        self.assert_no_output("unsupported")

    def test_external_unfinished_path_rejects_an_otherwise_safe_middle_block(self):
        # q/Q does not clear the path built before the candidate either.
        self.make_pdf(b"q 10 10 40 40 re Q\n" + WATERMARK + b"f\n")
        self.assert_no_output("unsupported")

    def test_finished_text_object_before_middle_block_is_safe(self):
        prefix = b"BT (TEXT) Tj ET\n"
        self.make_pdf(prefix + WATERMARK + BODY)
        self.assertEqual(self.process()["status"], "success")
        self.assertEqual(self.output_operations(), self.operations(prefix + BODY))

    def test_path_ending_operations_clear_external_path_before_middle_block(self):
        for index, operator in enumerate((b"n", b"S", b"s", b"f", b"F", b"f*",
                                          b"B", b"B*", b"b", b"b*")):
            with self.subTest(operator=operator):
                self.output = self.output.with_name(f"path-end-{index}.pdf")
                prefix = b"10 10 40 40 re\n" + operator + b"\n"
                self.make_pdf(prefix + WATERMARK + BODY)
                self.assertEqual(self.process()["status"], "success")
                self.assertEqual(self.output_operations(), self.operations(prefix + BODY))

    def test_text_path_clip_and_unknown_operations_inside_middle_block_are_rejected(self):
        for index, content in enumerate((
            b"BT ET", b"0 Tc", b"0 Tw", b"100 Tz", b"12 TL", b"/F0 10 Tf",
            b"0 Tr", b"0 Ts", b"20 0 Td", b"20 0 TD", b"1 0 0 1 0 0 Tm",
            b"T*", b"(WM) Tj", b"[(WM)] TJ", b"(WM) '", b'0 0 (WM) "',
            b"0 0 m", b"1 1 l", b"1 1 2 2 3 3 c", b"1 1 2 2 v",
            b"1 1 2 2 y", b"h", b"1 1 2 2 re", b"n", b"S", b"s", b"f",
            b"F", b"f*", b"B", b"B*", b"b", b"b*", b"W", b"W*", b"mystery",
        )):
            with self.subTest(content=content):
                self.output = self.output.with_name(f"rejected-op-{index}.pdf")
                self.make_pdf(START + b"q\n" + content + b"\nQ\nEMC\n" + BODY)
                self.assert_no_output("unsupported")

    def test_middle_form_xobject_invocation_is_safe(self):
        writer = PdfWriter()
        form = DecodedStreamObject()
        form.set_data(BODY)
        form.update({
            NameObject("/Type"): NameObject("/XObject"),
            NameObject("/Subtype"): NameObject("/Form"),
            NameObject("/BBox"): ArrayObject([FloatObject(n) for n in (0, 0, 100, 100)]),
            NameObject("/Resources"): DictionaryObject(),
        })
        resources = DictionaryObject({NameObject("/XObject"): DictionaryObject({
            NameObject("/Fm"): writer._add_object(form),
        })})
        page = writer.add_blank_page(width=100, height=100)
        page[NameObject("/Resources")] = resources
        stream = DecodedStreamObject()
        stream.set_data(START + b"q 1 0 0 1 2 3 cm /Fm Do Q\nEMC\n" + BODY)
        page[NameObject("/Contents")] = writer._add_object(stream)
        writer.write(self.input)

        result = self.process()
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["removed_blocks"], 1)
        self.assertEqual(self.output_operations(), self.operations(BODY))

    def test_inline_image_operator_name_and_middle_removal(self):
        self.assertIn(b"INLINE IMAGE", [operator for _, operator in self.operations(MARK)])
        self.make_pdf(WATERMARK + BODY)
        self.assertEqual(self.process()["status"], "success")
        self.assertEqual(self.output_operations(), self.operations(BODY))

    def test_tail_blocks_still_allow_text_and_path_operations(self):
        self.make_pdf(BODY + START + b"q BT (WM) Tj ET n mystery Q\nEMC\n")
        result = self.process()
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["removed_blocks"], 1)
        self.assertEqual(self.output_operations(), self.operations(BODY))

    def test_counts_three_watermarks_across_two_pages(self):
        self.make_pdf(WATERMARK + BODY, BODY + WATERMARK + WATERMARK)
        result = self.process()
        self.assertEqual(result["status"], "success")
        self.assertEqual((result["pages"], result["removed_blocks"]), (2, 3))
        self.assertEqual(len(PdfReader(self.output).pages), 2)
        for page in range(2):
            self.assertEqual(self.output_operations(page), self.operations(BODY))

    def test_preserves_body_stream_shared_with_an_unchanged_page(self):
        writer = PdfWriter()
        first = writer.add_blank_page(width=100, height=100)
        second = writer.add_blank_page(width=100, height=100)
        watermark = DecodedStreamObject()
        watermark.set_data(WATERMARK)
        body = DecodedStreamObject()
        body.set_data(BODY)
        body_reference = writer._add_object(body)
        first[NameObject("/Contents")] = ArrayObject([
            writer._add_object(watermark), body_reference,
        ])
        second[NameObject("/Contents")] = body_reference
        writer.write(self.input)

        result = self.process()
        self.assertEqual(result["status"], "success")
        self.assertEqual((result["pages"], result["removed_blocks"]), (2, 1))
        output = PdfReader(self.output)
        self.assertIsNotNone(output.pages[1].get_contents())
        for page in range(2):
            self.assertEqual(self.output_operations(page), self.operations(BODY))

    def test_counts_both_pages_that_share_the_entire_watermark_stream(self):
        writer = PdfWriter()
        shared = DecodedStreamObject()
        shared.set_data(WATERMARK + BODY)
        reference = writer._add_object(shared)
        for _ in range(2):
            page = writer.add_blank_page(width=100, height=100)
            page[NameObject("/Contents")] = reference
        writer.write(self.input)

        result = self.process()
        self.assertEqual(result["status"], "success")
        self.assertEqual((result["pages"], result["removed_blocks"]), (2, 2))
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
        nested = b"q\n/Span << /MCID 0 >> BDC\n/Span BMC\n" + MARK + b"EMC\nEMC\nQ\n"
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

    def test_existing_output_is_preserved_and_returns_failed(self):
        self.make_pdf(WATERMARK + BODY)
        original = b"existing output must not be replaced"
        self.output.write_bytes(original)

        self.assertEqual(self.process()["status"], "failed")
        self.assertEqual(self.output.read_bytes(), original)

    def test_existing_output_preserves_unsupported_input_status(self):
        self.make_pdf(BODY)
        original = b"existing output with unsupported input"
        self.output.write_bytes(original)

        self.assertEqual(self.process()["status"], "unsupported")
        self.assertEqual(self.output.read_bytes(), original)

    def test_existing_output_preserves_invalid_input_status(self):
        self.make_pdf(START + MARK)
        original = b"existing output with invalid input"
        self.output.write_bytes(original)

        self.assertEqual(self.process()["status"], "invalid")
        self.assertEqual(self.output.read_bytes(), original)

    def test_existing_output_preserves_encrypted_input_status(self):
        self.make_pdf(WATERMARK + BODY, password="user-secret")
        original = b"existing output with encrypted input"
        self.output.write_bytes(original)

        self.assertEqual(self.process()["status"], "encrypted")
        self.assertEqual(self.output.read_bytes(), original)

    def test_existing_output_is_preserved_when_writer_would_fail(self):
        self.make_pdf(WATERMARK + BODY)
        original = b"existing output must survive a write failure"
        self.output.write_bytes(original)
        writes = []

        def interrupted_write(writer, destination):
            writes.append(True)
            destination.write(b"partial replacement")
            raise OSError("simulated interrupted write")

        with patch.object(PdfWriter, "write", interrupted_write):
            self.assertEqual(self.process()["status"], "failed")
        self.assertTrue(self.output.exists(), "existing output was deleted")
        self.assertEqual(self.output.read_bytes(), original)
        self.assertEqual(writes, [], "existing output must be rejected before writing")

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
