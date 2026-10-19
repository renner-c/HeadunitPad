"""Unit tests for scripts/check_ios14_imports.py (stdlib unittest, no device or SDK needed)."""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import check_ios14_imports as c  # noqa: E402

# --------------------------------------------------------------------------- fixtures

TBD_V3 = """\
--- !tapi-tbd-v3
archs:                 [ armv7, armv7s, arm64, arm64e ]
platform:              ios
flags:                 [ flat_namespace ]
install-name:          /System/Library/Frameworks/Foo.framework/Foo
current-version:       1.0
compatibility-version: 1
objc-constraint:       retain_release
exports:
  - archs:                [ armv7, armv7s, arm64, arm64e ]
    re-exports:           [ /System/Library/PrivateFrameworks/FooCore.framework/FooCore,
                            /usr/lib/libbar.dylib ]
    symbols:              [ _FooFunc, _kFooConstant, '$ld$hide$os13.0$_old',
                            _FooMulti ]
    objc-classes:         [ FooView, FooController ]
    objc-eh-types:        [ FooException ]
    objc-ivars:           [ FooView._storage ]
    weak-def-symbols:     [ __ZN3foo3barEv ]
    thread-local-symbols: [ _fooTLS ]
  - archs:                [ armv7 ]
    symbols:              [ _FooOnlyArmv7 ]
  - archs:                [ arm64 ]
    symbols:              [ _FooOnlyArm64 ]
undefineds:
  - archs:                [ armv7, armv7s, arm64, arm64e ]
    symbols:              [ dyld_stub_binder, _NotAnExport ]
...
"""

TBD_V4 = """\
--- !tapi-tbd
tbd-version:     4
targets:         [ armv7-ios, arm64-ios, arm64e-ios, x86_64-ios-simulator ]
uuids:
  - target:          armv7-ios
    value:           00000000-0000-0000-0000-000000000000
install-name:    '/usr/lib/libumbrella.dylib'
current-version: 1
reexported-libraries:
  - targets:         [ arm64-ios, arm64e-ios ]
    libraries:       [ /usr/lib/system/libinner.dylib ]
  - targets:         [ armv7-ios ]
    libraries:       [ /usr/lib/system/libarmv7only.dylib ]
exports:
  - targets:         [ arm64-ios, arm64e-ios ]
    symbols:         [ _umbrellaSym ]
    objc-classes:    [ Widget ]
    objc-eh-types:   [ WidgetError ]
    objc-ivars:      [ Widget._x ]
    weak-symbols:    [ _weakSym ]
    thread-local-symbols: [ _tlsSym ]
  - targets:         [ armv7-ios ]
    symbols:         [ _armv7Sym ]
  - targets:         [ x86_64-ios-simulator ]
    symbols:         [ _simSym ]
--- !tapi-tbd
tbd-version:     4
targets:         [ arm64-ios ]
install-name:    '/usr/lib/system/libinline.dylib'
parent-umbrella:
  - targets:         [ arm64-ios ]
    umbrella:        umbrella
exports:
  - targets:         [ arm64-ios ]
    symbols:         [ _inlineSym ]
...
"""

DYLD_INFO_IMPORTS = """\
HeadunitPad [arm64]:
    -imports:
      0x0000  _BIO_ctrl  (from OpenSSL)
      0x0023  _CFArrayGetCount  (from CoreFoundation)
      0x00D7  __availability_version_check [weak-import] (from libSystem)
      0x01FC  _swift_getExtendedFunctionTypeMetadata [weak-import] (from libswiftCore)
      0x0214  _swift_unknownObjectWeakAssign  (from libswiftCore)
      0x0300  _OBJC_CLASS_$_UIButtonConfiguration [weak-import] (from UIKit)
      0x0301  _flat_thing  (flat lookup)
"""

NM_UNDEFINED = """\
                 (undefined) external _$s10Foundation12CharacterSetVMa (from Foundation)
                 (undefined) external _CFArrayGetCount (from CoreFoundation)
                 (undefined) weak external _OBJC_CLASS_$_AVAudioApplication (from AVFAudio)
                 (undefined) external _objc_msgSend (from libobjc)
                 (undefined) external _dyld_flat (dynamically looked up)
"""

OTOOL_L = """\
Load command 4
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 2
    minos 16.6
      sdk 26.2
   ntools 1
     tool 3
Load command 5
          cmd LC_LOAD_DYLIB
      cmdsize 64
         name @rpath/OpenSSL.framework/OpenSSL (offset 24)
   time stamp 2 Wed Dec 31 16:00:02 1969
      current version 1.0.0
compatibility version 1.0.0
Load command 6
          cmd LC_LOAD_WEAK_DYLIB
      cmdsize 72
         name /usr/lib/swift/libswiftAVFoundation.dylib (offset 24)
   time stamp 2 Wed Dec 31 16:00:02 1969
      current version 2395.6.1
compatibility version 1.0.0
Load command 7
          cmd LC_REEXPORT_DYLIB
      cmdsize 64
         name @rpath/Inner.framework/Inner (offset 24)
   time stamp 2 Wed Dec 31 16:00:02 1969
      current version 1.0.0
compatibility version 1.0.0
Load command 8
          cmd LC_RPATH
      cmdsize 40
         path @executable_path/Frameworks (offset 12)
Load command 9
          cmd LC_ID_DYLIB
      cmdsize 64
         name @rpath/Self.framework/Self (offset 24)
   time stamp 1 Wed Dec 31 16:00:01 1969
      current version 1.0.0
compatibility version 1.0.0
"""

OTOOL_L_OLD = """\
Load command 9
      cmd LC_VERSION_MIN_IPHONEOS
  cmdsize 16
  version 9.0
      sdk 14.0
"""

OTOOL_L_MAC = """\
Load command 4
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 11.0
      sdk 12.0
"""


def lib(path, weak=False, reexport=False):
    return c.LinkedLib(path, weak, reexport)


# --------------------------------------------------------------------------- tests


class VersionTests(unittest.TestCase):
    def test_parse_and_compare(self):
        self.assertEqual(c.parse_version("14.3"), (14, 3, 0))
        self.assertEqual(c.parse_version("14.3.1"), (14, 3, 1))
        self.assertEqual(c.parse_version("16"), (16, 0, 0))
        self.assertGreater(c.parse_version("14.3.1"), c.parse_version("14.3"))
        self.assertLess(c.parse_version("9.0"), c.parse_version("14.3"))


class TbdV3Tests(unittest.TestCase):
    def setUp(self):
        self.docs = c.parse_tbd(TBD_V3, "arm64")

    def test_one_doc_with_install_name(self):
        self.assertEqual(len(self.docs), 1)
        self.assertEqual(self.docs[0].install_name, "/System/Library/Frameworks/Foo.framework/Foo")

    def test_plain_symbols_including_multiline_and_quoted(self):
        s = self.docs[0].symbols
        for sym in ("_FooFunc", "_kFooConstant", "_FooMulti", "$ld$hide$os13.0$_old"):
            self.assertIn(sym, s)

    def test_objc_classes_expand_to_class_and_metaclass(self):
        s = self.docs[0].symbols
        self.assertIn("_OBJC_CLASS_$_FooView", s)
        self.assertIn("_OBJC_METACLASS_$_FooView", s)
        self.assertIn("_OBJC_CLASS_$_FooController", s)
        self.assertIn("_OBJC_METACLASS_$_FooController", s)

    def test_objc_eh_types_and_ivars(self):
        s = self.docs[0].symbols
        self.assertIn("_OBJC_EHTYPE_$_FooException", s)
        self.assertIn("_OBJC_IVAR_$_FooView._storage", s)

    def test_weak_def_and_thread_local(self):
        s = self.docs[0].symbols
        self.assertIn("__ZN3foo3barEv", s)
        self.assertIn("_fooTLS", s)

    def test_reexports(self):
        self.assertEqual(
            self.docs[0].reexports,
            ["/System/Library/PrivateFrameworks/FooCore.framework/FooCore", "/usr/lib/libbar.dylib"],
        )

    def test_arch_sections_filtered(self):
        s = self.docs[0].symbols
        self.assertIn("_FooOnlyArm64", s)
        self.assertNotIn("_FooOnlyArmv7", s)

    def test_undefineds_ignored(self):
        self.assertNotIn("_NotAnExport", self.docs[0].symbols)
        self.assertNotIn("dyld_stub_binder", self.docs[0].symbols)

    def test_other_arch_selects_other_section(self):
        docs = c.parse_tbd(TBD_V3, "armv7")
        self.assertIn("_FooOnlyArmv7", docs[0].symbols)
        self.assertNotIn("_FooOnlyArm64", docs[0].symbols)


class TbdV4Tests(unittest.TestCase):
    def setUp(self):
        self.docs = c.parse_tbd(TBD_V4, "arm64")

    def test_multiple_documents(self):
        self.assertEqual(
            [d.install_name for d in self.docs],
            ["/usr/lib/libumbrella.dylib", "/usr/lib/system/libinline.dylib"],
        )

    def test_target_filtered_symbols(self):
        s = self.docs[0].symbols
        self.assertIn("_umbrellaSym", s)
        self.assertIn("_weakSym", s)
        self.assertIn("_tlsSym", s)
        self.assertNotIn("_armv7Sym", s)
        self.assertNotIn("_simSym", s)

    def test_objc(self):
        s = self.docs[0].symbols
        self.assertIn("_OBJC_CLASS_$_Widget", s)
        self.assertIn("_OBJC_METACLASS_$_Widget", s)
        self.assertIn("_OBJC_EHTYPE_$_WidgetError", s)
        self.assertIn("_OBJC_IVAR_$_Widget._x", s)

    def test_reexported_libraries_filtered_by_target(self):
        self.assertEqual(self.docs[0].reexports, ["/usr/lib/system/libinner.dylib"])

    def test_inline_second_document(self):
        self.assertIn("_inlineSym", self.docs[1].symbols)
        self.assertEqual(self.docs[1].reexports, [])

    def test_quoted_install_name_unquoted(self):
        self.assertEqual(self.docs[0].install_name, "/usr/lib/libumbrella.dylib")


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def mini_tbd(install_name, symbols, reexports=(), classes=()):
    parts = ["--- !tapi-tbd-v3", "archs: [ arm64 ]", "platform: ios", "install-name: " + install_name, "exports:"]
    parts.append("  - archs: [ arm64 ]")
    if reexports:
        parts.append("    re-exports: [ " + ", ".join(reexports) + " ]")
    if symbols:
        parts.append("    symbols: [ " + ", ".join(symbols) + " ]")
    if classes:
        parts.append("    objc-classes: [ " + ", ".join(classes) + " ]")
    parts.append("...")
    return "\n".join(parts) + "\n"


class SdkIndexTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        r = self.root
        write(
            r + "/System/Library/Frameworks/UIKit.framework/UIKit.tbd",
            mini_tbd(
                "/System/Library/Frameworks/UIKit.framework/UIKit",
                ["_UIApplicationMain"],
                reexports=["/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore"],
            ),
        )
        write(
            r + "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore.tbd",
            mini_tbd(
                "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore",
                [],
                classes=["UIButton"],
            ),
        )
        write(
            r + "/usr/lib/libSystem.tbd",
            mini_tbd("/usr/lib/libSystem.B.dylib", ["_malloc"], reexports=["/usr/lib/system/libsystem_c.dylib"]),
        )
        write(r + "/usr/lib/system/libsystem_c.tbd", mini_tbd("/usr/lib/system/libsystem_c.dylib", ["_printf"]))
        # cycle: a <-> b
        write(r + "/usr/lib/liba.tbd", mini_tbd("/usr/lib/liba.dylib", ["_a"], reexports=["/usr/lib/libb.dylib"]))
        write(r + "/usr/lib/libb.tbd", mini_tbd("/usr/lib/libb.dylib", ["_b"], reexports=["/usr/lib/liba.dylib"]))
        # tbd whose file name does not match its install name
        write(r + "/usr/lib/weird_name.tbd", mini_tbd("/usr/lib/libodd.dylib", ["_odd"]))
        # v4 with inline reexported doc
        write(r + "/usr/lib/libumbrella.tbd", TBD_V4)
        self.sdk = c.SdkIndex(self.root, "arm64")

    def tearDown(self):
        self.tmp.cleanup()

    def test_has_library(self):
        self.assertTrue(self.sdk.has_library("/System/Library/Frameworks/UIKit.framework/UIKit"))
        self.assertTrue(self.sdk.has_library("/usr/lib/libSystem.B.dylib"))
        self.assertFalse(self.sdk.has_library("/usr/lib/swift/libswift_Concurrency.dylib"))

    def test_has_library_via_install_name_index(self):
        self.assertTrue(self.sdk.has_library("/usr/lib/libodd.dylib"))

    def test_versioned_framework_path_resolves(self):
        write(
            self.root + "/System/Library/Frameworks/IOKit.framework/IOKit.tbd",
            mini_tbd("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", ["_IOServiceOpen"]),
        )
        sdk = c.SdkIndex(self.root, "arm64")
        self.assertIn("_IOServiceOpen", sdk.exports("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit"))
        self.assertIn("_IOServiceOpen", sdk.exports("/System/Library/Frameworks/IOKit.framework/IOKit"))

    def test_exports_follow_reexports_umbrella(self):
        e = self.sdk.exports("/System/Library/Frameworks/UIKit.framework/UIKit")
        self.assertIn("_UIApplicationMain", e)
        self.assertIn("_OBJC_CLASS_$_UIButton", e)
        self.assertIn("_OBJC_METACLASS_$_UIButton", e)

    def test_exports_follow_system_umbrella(self):
        e = self.sdk.exports("/usr/lib/libSystem.B.dylib")
        self.assertIn("_malloc", e)
        self.assertIn("_printf", e)

    def test_cycle_does_not_loop(self):
        e = self.sdk.exports("/usr/lib/liba.dylib")
        self.assertEqual({"_a", "_b"}, set(e))

    def test_missing_library_returns_none(self):
        self.assertIsNone(self.sdk.exports("/usr/lib/swift/libswift_Concurrency.dylib"))

    def test_inline_v4_reexport_document(self):
        e = self.sdk.exports("/usr/lib/libumbrella.dylib")
        self.assertIn("_umbrellaSym", e)
        # libinner is not in the SDK and not inline -> contributes nothing, no crash
        self.assertNotIn("_inlineSym", e)

    def test_inline_doc_reexported_when_listed(self):
        text = TBD_V4.replace("/usr/lib/system/libinner.dylib", "/usr/lib/system/libinline.dylib")
        write(self.root + "/usr/lib/libumbrella.tbd", text)
        sdk = c.SdkIndex(self.root, "arm64")
        self.assertIn("_inlineSym", sdk.exports("/usr/lib/libumbrella.dylib"))


class ImportParserTests(unittest.TestCase):
    def test_dyld_info(self):
        imps = c.parse_dyld_info_imports(DYLD_INFO_IMPORTS)
        self.assertEqual(len(imps), 7)
        by = {i.symbol: i for i in imps}
        self.assertEqual(by["_BIO_ctrl"], c.Import("_BIO_ctrl", "OpenSSL", False))
        self.assertEqual(by["__availability_version_check"], c.Import("__availability_version_check", "libSystem", True))
        self.assertTrue(by["_OBJC_CLASS_$_UIButtonConfiguration"].weak)
        self.assertEqual(by["_OBJC_CLASS_$_UIButtonConfiguration"].lib, "UIKit")
        self.assertIsNone(by["_flat_thing"].lib)
        self.assertFalse(by["_swift_unknownObjectWeakAssign"].weak)  # "Weak" inside a name is not the flag

    def test_dyld_info_without_offset_column(self):
        text = (
            "Frameworks/OpenSSL.framework/OpenSSL [arm64]:\n"
            "    -imports:\n"
            "      _CCRandomGenerateBytes  (from libSystem)\n"
            "      ___error  [weak-import] (from libSystem)\n"
        )
        self.assertEqual(
            c.parse_dyld_info_imports(text),
            [c.Import("_CCRandomGenerateBytes", "libSystem", False), c.Import("___error", "libSystem", True)],
        )

    def test_nm(self):
        imps = c.parse_nm_undefined(NM_UNDEFINED)
        self.assertEqual(len(imps), 5)
        by = {i.symbol: i for i in imps}
        self.assertEqual(by["_$s10Foundation12CharacterSetVMa"], c.Import("_$s10Foundation12CharacterSetVMa", "Foundation", False))
        self.assertEqual(by["_OBJC_CLASS_$_AVAudioApplication"], c.Import("_OBJC_CLASS_$_AVAudioApplication", "AVFAudio", True))
        self.assertIsNone(by["_dyld_flat"].lib)
        self.assertFalse(by["_objc_msgSend"].weak)

    def test_both_parsers_agree_on_shared_shape(self):
        a = c.parse_dyld_info_imports("    -imports:\n      0x0000  _x  [weak-import] (from Foundation)\n")
        b = c.parse_nm_undefined("  (undefined) weak external _x (from Foundation)\n")
        self.assertEqual(a, b)


class MachOParserTests(unittest.TestCase):
    def test_build_version(self):
        info = c.parse_otool_l(OTOOL_L)
        self.assertEqual(info.minos, (16, 6, 0))
        self.assertEqual(info.platform, "ios")

    def test_libs_and_flags(self):
        info = c.parse_otool_l(OTOOL_L)
        self.assertEqual(
            info.libs,
            [
                c.LinkedLib("@rpath/OpenSSL.framework/OpenSSL", False, False),
                c.LinkedLib("/usr/lib/swift/libswiftAVFoundation.dylib", True, False),
                c.LinkedLib("@rpath/Inner.framework/Inner", False, True),
            ],
        )

    def test_rpath_and_id(self):
        info = c.parse_otool_l(OTOOL_L)
        self.assertEqual(info.rpaths, ["@executable_path/Frameworks"])
        self.assertEqual(info.install_id, "@rpath/Self.framework/Self")

    def test_legacy_version_min(self):
        info = c.parse_otool_l(OTOOL_L_OLD)
        self.assertEqual(info.minos, (9, 0, 0))
        self.assertEqual(info.platform, "ios")

    def test_non_ios_platform(self):
        info = c.parse_otool_l(OTOOL_L_MAC)
        self.assertEqual(info.platform, "macos")

    def test_vtool_style_platform_name(self):
        info = c.parse_otool_l("      cmd LC_BUILD_VERSION\n platform IOS\n    minos 14.0\n")
        self.assertEqual(info.platform, "ios")


class LeafNameTests(unittest.TestCase):
    def test_leaf(self):
        self.assertEqual(c.leaf_name("/usr/lib/libobjc.A.dylib"), "libobjc")
        self.assertEqual(c.leaf_name("/usr/lib/libSystem.B.dylib"), "libSystem")
        self.assertEqual(c.leaf_name("/usr/lib/libc++.1.dylib"), "libc++")
        self.assertEqual(c.leaf_name("/System/Library/Frameworks/UIKit.framework/UIKit"), "UIKit")
        self.assertEqual(c.leaf_name("@rpath/OpenSSL.framework/OpenSSL"), "OpenSSL")
        self.assertEqual(c.leaf_name("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit"), "IOKit")
        self.assertEqual(c.leaf_name("/usr/lib/swift/libswiftCore.dylib"), "libswiftCore")


# Resolution helper for verdict tests: dict of install path -> LibResolution.
def make_resolver(table):
    def resolve(linked):
        return table.get(linked.path, c.LibResolution("missing", None))

    return resolve


class VerdictTests(unittest.TestCase):
    def info(self, minos=(14, 0, 0), platform="ios", libs=()):
        return c.MachOInfo(minos=minos, platform=platform, install_id=None, libs=list(libs), rpaths=[])

    def test_clean_binary_passes(self):
        info = self.info(libs=[lib("/usr/lib/libSystem.B.dylib")])
        res = make_resolver({"/usr/lib/libSystem.B.dylib": c.LibResolution("found", frozenset({"_malloc"}))})
        rep = c.evaluate_binary("A", info, [c.Import("_malloc", "libSystem", False)], res)
        self.assertTrue(rep.ok)
        self.assertEqual(rep.errors, [])

    def test_minos_over_limit_fails(self):
        rep = c.evaluate_binary("A", self.info(minos=(16, 6, 0)), [], make_resolver({}))
        self.assertFalse(rep.ok)
        self.assertEqual(rep.errors[0].kind, "minos")

    def test_minos_equal_limit_passes_and_patch_fails(self):
        self.assertTrue(c.evaluate_binary("A", self.info(minos=(14, 3, 0)), [], make_resolver({})).ok)
        self.assertFalse(c.evaluate_binary("A", self.info(minos=(14, 3, 1)), [], make_resolver({})).ok)

    def test_missing_minos_fails(self):
        rep = c.evaluate_binary("A", self.info(minos=None), [], make_resolver({}))
        self.assertFalse(rep.ok)

    def test_wrong_platform_fails(self):
        rep = c.evaluate_binary("A", self.info(platform="macos"), [], make_resolver({}))
        self.assertFalse(rep.ok)
        self.assertEqual(rep.errors[0].kind, "platform")

    def test_missing_nonweak_symbol_fails(self):
        info = self.info(libs=[lib("/System/Library/Frameworks/UIKit.framework/UIKit")])
        res = make_resolver(
            {"/System/Library/Frameworks/UIKit.framework/UIKit": c.LibResolution("found", frozenset({"_UIApplicationMain"}))}
        )
        imps = [
            c.Import("_UIApplicationMain", "UIKit", False),
            c.Import("_OBJC_CLASS_$_UIButtonConfiguration", "UIKit", False),
        ]
        rep = c.evaluate_binary("A", info, imps, res)
        self.assertFalse(rep.ok)
        self.assertEqual([e.kind for e in rep.errors], ["symbol"])
        self.assertEqual(rep.errors[0].lib, "UIKit")
        self.assertEqual(rep.errors[0].symbol, "_OBJC_CLASS_$_UIButtonConfiguration")

    def test_missing_weak_symbol_is_note_not_error(self):
        info = self.info(libs=[lib("/System/Library/Frameworks/UIKit.framework/UIKit")])
        res = make_resolver({"/System/Library/Frameworks/UIKit.framework/UIKit": c.LibResolution("found", frozenset())})
        rep = c.evaluate_binary("A", info, [c.Import("_OBJC_CLASS_$_AVAudioApplication", "UIKit", True)], res)
        self.assertTrue(rep.ok)
        self.assertEqual([n.kind for n in rep.notes], ["weak-symbol"])
        self.assertIn("weak (nil at runtime on 14.3)", c.format_finding(rep.notes[0]))

    def test_missing_nonweak_library_fails_and_suppresses_symbol_errors(self):
        info = self.info(libs=[lib("/usr/lib/swift/libswift_Concurrency.dylib")])
        imps = [c.Import("_a", "libswift_Concurrency", False), c.Import("_b", "libswift_Concurrency", False)]
        rep = c.evaluate_binary("A", info, imps, make_resolver({}))
        self.assertFalse(rep.ok)
        self.assertEqual([e.kind for e in rep.errors], ["library"])
        self.assertIn("2", c.format_finding(rep.errors[0]))  # mentions how many imports are affected

    def test_missing_weak_library_is_note(self):
        info = self.info(libs=[lib("/usr/lib/swift/libswiftXPC.dylib", weak=True)])
        rep = c.evaluate_binary("A", info, [c.Import("_x", "libswiftXPC", False)], make_resolver({}))
        self.assertTrue(rep.ok)
        self.assertEqual([n.kind for n in rep.notes], ["weak-library"])

    def test_weak_library_import_marked_nonweak_still_ok(self):
        # symbol imports from an absent weak library are not individually errors
        info = self.info(libs=[lib("/usr/lib/swift/libswiftXPC.dylib", weak=True)])
        imps = [c.Import("_x", "libswiftXPC", False), c.Import("_y", "libswiftXPC", False)]
        rep = c.evaluate_binary("A", info, imps, make_resolver({}))
        self.assertTrue(rep.ok)

    def test_external_library_is_note_not_checked(self):
        info = self.info(libs=[lib("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate")])
        res = make_resolver(
            {"/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate": c.LibResolution("external", None)}
        )
        rep = c.evaluate_binary("A", info, [c.Import("_MSHookFunction", "CydiaSubstrate", False)], res)
        self.assertTrue(rep.ok)
        self.assertEqual([n.kind for n in rep.notes], ["external-library"])

    def test_flat_lookup_import_checked_against_all_libs(self):
        info = self.info(libs=[lib("/usr/lib/libA.dylib"), lib("/usr/lib/libB.dylib")])
        res = make_resolver(
            {
                "/usr/lib/libA.dylib": c.LibResolution("found", frozenset({"_a"})),
                "/usr/lib/libB.dylib": c.LibResolution("found", frozenset({"_b"})),
            }
        )
        rep = c.evaluate_binary("A", info, [c.Import("_b", None, False), c.Import("_zzz", None, False)], res)
        self.assertEqual([e.symbol for e in rep.errors], ["_zzz"])

    def test_weak_def_coalesce_import_is_not_an_error(self):
        info = self.info(libs=[lib("/usr/lib/libc++.1.dylib")])
        res = make_resolver({"/usr/lib/libc++.1.dylib": c.LibResolution("found", frozenset({"_x"}))})
        imports = [c.Import("__Znwm", "<weak-def-coalesce>", False), c.Import("__ZdlPv", "<weak-def-coalesce>", False)]
        rep = c.evaluate_binary("A", info, imports, res)
        self.assertTrue(rep.ok)

    def test_system_rpath_install_names(self):
        self.assertEqual(
            c.system_rpath_install_names(
                ["@executable_path/Frameworks", "/usr/lib/swift", "/Library/Foo"], "libswiftCore.dylib"
            ),
            ["/usr/lib/swift/libswiftCore.dylib"],
        )

    def test_import_from_unlinked_library_is_error(self):
        rep = c.evaluate_binary("A", self.info(), [c.Import("_x", "Mystery", False)], make_resolver({}))
        self.assertFalse(rep.ok)
        self.assertEqual(rep.errors[0].kind, "symbol")

    def test_leaf_name_resolves_versioned_dylib(self):
        info = self.info(libs=[lib("/usr/lib/libobjc.A.dylib")])
        res = make_resolver({"/usr/lib/libobjc.A.dylib": c.LibResolution("found", frozenset({"_objc_msgSend"}))})
        rep = c.evaluate_binary("A", info, [c.Import("_objc_msgSend", "libobjc", False)], res)
        self.assertTrue(rep.ok)

    def test_custom_max_minos(self):
        rep = c.evaluate_binary("A", self.info(minos=(15, 0, 0)), [], make_resolver({}), max_minos=(15, 0, 0))
        self.assertTrue(rep.ok)


class RpathResolutionTests(unittest.TestCase):
    def test_expand_rpath_entries(self):
        got = c.expand_rpath_candidates(
            "@rpath/OpenSSL.framework/OpenSSL",
            rpaths=["@executable_path/Frameworks", "@loader_path/Frameworks"],
            executable_dir="/b/App.app",
            loader_dir="/b/App.app/Frameworks/X.framework",
        )
        self.assertIn("/b/App.app/Frameworks/OpenSSL.framework/OpenSSL", got)
        self.assertIn("/b/App.app/Frameworks/X.framework/Frameworks/OpenSSL.framework/OpenSSL", got)

    def test_executable_path_prefix(self):
        got = c.expand_rpath_candidates(
            "@executable_path/Frameworks/Foo.dylib", rpaths=[], executable_dir="/b/App.app", loader_dir="/b/App.app"
        )
        self.assertEqual(got, ["/b/App.app/Frameworks/Foo.dylib"])


if __name__ == "__main__":
    unittest.main()
