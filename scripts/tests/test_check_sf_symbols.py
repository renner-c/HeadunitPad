"""Unit tests for scripts/check_sf_symbols.py (stdlib unittest, uses a fixture plist, no macOS needed)."""

import contextlib
import io
import os
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import check_sf_symbols as c  # noqa: E402

FIXTURE = {
    "symbols": {
        "wifi": "2019",
        "gearshape.fill": "2020",
        "mic.fill": "2020.1",
        "bolt.horizontal": "2019",
        "cable.connector": "2021",
        "tray.full": "2021.1",
        "sparkles": "2022",
    },
    "year_to_release": {
        "2019": {"iOS": "13.0", "macOS": "10.15"},
        "2020": {"iOS": "14.0"},
        "2020.1": {"iOS": "14.2"},
        "2021": {"iOS": "15.0"},
        "2021.1": {"iOS": "15.1"},
        "2022": {"iOS": "16.0"},
    },
}


def availability():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "name_availability.plist")
        with open(path, "wb") as handle:
            plistlib.dump(FIXTURE, handle)
        return c.load_availability(path)


MAX = c.parse_version("14.3")


def problems_for(source):
    return c.check_uses(c.extract_uses(source, "T.swift"), availability(), MAX)


class ExtractTests(unittest.TestCase):
    def test_single_literals_from_both_parameter_names(self):
        src = (
            'let a = HeadunitButton(style: .tinted, title: "x", systemImageName: "wifi")\n'
            'let b = UIImage(systemName: "gearshape.fill")\n'
        )
        uses = c.extract_uses(src)
        self.assertEqual([(u.line, u.names, u.is_fallback_list) for u in uses],
                         [(1, ("wifi",), False), (2, ("gearshape.fill",), False)])

    def test_fallback_list_spanning_lines(self):
        src = 'HeadunitButton(style: .tinted, systemImageNames: [\n  "cable.connector",\n  "bolt.horizontal",\n])\n'
        uses = c.extract_uses(src)
        self.assertEqual(len(uses), 1)
        self.assertEqual(uses[0].names, ("cable.connector", "bolt.horizontal"))
        self.assertTrue(uses[0].is_fallback_list)

    def test_comments_are_ignored_but_urls_in_strings_are_not_comments(self):
        src = (
            '// systemName: "sparkles"\n'
            '/* systemImageName: "sparkles" */\n'
            'let url = "http://x"; let i = UIImage(systemName: "wifi")\n'
        )
        uses = c.extract_uses(src)
        self.assertEqual([u.names for u in uses], [("wifi",)])
        self.assertEqual(uses[0].line, 3)

    def test_non_literal_arguments_are_skipped(self):
        self.assertEqual(c.extract_uses("UIImage(systemName: name)"), [])

    def test_declarations_and_computed_lists_are_skipped(self):
        src = (
            "init(systemImageNames: [String] = [], x: Int)\n"
            "self.init(systemImageNames: systemImageName.map { [$0] } ?? [])\n"
        )
        self.assertEqual(c.extract_uses(src), [])


class CheckTests(unittest.TestCase):
    def test_old_symbols_pass(self):
        self.assertEqual(problems_for('f(systemImageName: "wifi")\nf(systemName: "mic.fill")'), [])

    def test_symbol_newer_than_14_3_fails_with_location(self):
        problems = problems_for('\nf(systemImageName: "cable.connector")')
        self.assertEqual(len(problems), 1)
        self.assertIn("T.swift:2", problems[0])
        self.assertIn("cable.connector", problems[0])
        self.assertIn("15.0", problems[0])

    def test_new_symbol_allowed_in_list_with_old_fallback(self):
        self.assertEqual(problems_for('f(systemImageNames: ["cable.connector", "bolt.horizontal"])'), [])

    def test_fallback_order_does_not_matter_for_the_rule(self):
        self.assertEqual(problems_for('f(systemImageNames: ["bolt.horizontal", "cable.connector"])'), [])

    def test_list_of_only_new_symbols_fails_for_each_new_symbol(self):
        problems = problems_for('f(systemImageNames: ["cable.connector", "sparkles"])')
        self.assertEqual(len(problems), 2)
        self.assertTrue(all("no symbol available" in p for p in problems))

    def test_unknown_symbol_always_fails_even_in_a_list(self):
        problems = problems_for('f(systemImageNames: ["not.a.symbol", "wifi"])')
        self.assertEqual(len(problems), 1)
        self.assertIn("unknown SF Symbol 'not.a.symbol'", problems[0])

    def test_boundary_release_14_2_is_fine_and_15_1_is_not(self):
        self.assertEqual(problems_for('f(systemName: "mic.fill")'), [])
        self.assertEqual(len(problems_for('f(systemName: "tray.full")')), 1)

    def test_empty_list_is_reported(self):
        self.assertEqual(len(problems_for("f(systemImageNames: [])")), 1)


class CliTests(unittest.TestCase):
    def run_main(self, source, plist=True):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "src")
            os.makedirs(os.path.join(root, "Sub"))
            with open(os.path.join(root, "Sub", "A.swift"), "w") as handle:
                handle.write(source)
            plist_path = os.path.join(tmp, "p.plist")
            if plist:
                with open(plist_path, "wb") as handle:
                    plistlib.dump(FIXTURE, handle)
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = c.main(["--root", root, "--plist", plist_path])
            return code, out.getvalue(), err.getvalue()

    def test_exit_zero_when_clean(self):
        code, out, _ = self.run_main('f(systemImageName: "wifi")')
        self.assertEqual(code, 0)
        self.assertIn("Checked 1 SF Symbol use", out)

    def test_exit_one_on_violation(self):
        code, out, _ = self.run_main('f(systemImageName: "sparkles")')
        self.assertEqual(code, 1)
        self.assertIn("sparkles", out)

    def test_exit_two_when_database_missing(self):
        code, _, err = self.run_main("", plist=False)
        self.assertEqual(code, 2)
        self.assertIn("not found", err)


class RepoTests(unittest.TestCase):
    """The real source tree must pass against the real database when it is available (macOS)."""

    @unittest.skipUnless(os.path.isfile(c.DEFAULT_PLIST), "CoreGlyphs database not available")
    def test_app_sources_use_only_ios_14_3_symbols(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = c.main([])
        self.assertEqual(code, 0, out.getvalue())


if __name__ == "__main__":
    unittest.main()
