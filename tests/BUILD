package(default_testonly = 1)

load("@io_tweag_rules_haskell//haskell:haskell.bzl",
     "haskell_binary",
     "haskell_import",
     "haskell_library",
)

load("@bazel_tools//tools/build_rules:test_rules.bzl", "rule_test")

rule_test(
  name = "test-binary-simple",
  generates = ["binary-simple"],
  rule = "//tests/binary-simple",
  size = "small",
)

rule_test(
  name = "test-binary-with-lib",
  generates = ["binary-with-lib"],
  rule = "//tests/binary-with-lib",
  size = "small",
)

rule_test(
  name = "test-binary-with-prebuilt",
  generates = ["binary-with-prebuilt"],
  rule = "//tests/binary-with-prebuilt",
  size = "small",
)

rule_test(
  name = "test-binary-with-main",
  generates = ["binary-with-main"],
  rule = "//tests/binary-with-main",
  size = "small",
)

rule_test(
  name = "test-binary-with-sysdeps",
  generates = ["binary-with-sysdeps"],
  rule = "//tests/binary-with-sysdeps",
  size = "small",
)

rule_test(
  name = "test-library-deps",
  generates =
    ["library-deps-1.0.0/library-deps-1.0.0.conf",
     "library-deps-1.0.0/package.cache",
    ],
  rule = "//tests/library-deps",
  size = "small",
)

rule_test(
  name = "test-library-with-sysdeps",
  generates =
    ["library-with-sysdeps-1.0.0/library-with-sysdeps-1.0.0.conf",
     "library-with-sysdeps-1.0.0/package.cache",
    ],
  rule = "//tests/library-with-sysdeps",
  size = "small",
)

rule_test(
  name = "test-hsc",
  generates = ["hsc"],
  rule = "//tests/hsc",
  size = "small",
)