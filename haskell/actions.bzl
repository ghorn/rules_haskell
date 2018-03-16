"""A Haskell toolchain."""

load(":path_utils.bzl",
     "declare_compiled",
     "target_unique_name",
     "module_name",
     "import_hierarchy_root",
     "get_external_libs_path",
)

load(":set.bzl", "set")

load(":tools.bzl",
     "get_ghc_version",
     "tools",
)

load(":hsc2hs.bzl",
     "hsc_to_hs",
)

load(":cc.bzl", "cc_headers")

load(":java_interop.bzl",
     "JavaInteropInfo",
     "java_interop_info",
)

load(":providers.bzl",
     "HaskellBuildInfo",
     "HaskellLibraryInfo",
     "HaskellBinaryInfo",
     "CcSkylarkApiProviderHacked",
)

load("@bazel_skylib//:lib.bzl", "paths", "dicts")

load(":mode.bzl",
     "is_profiling_enabled",
)

load(":utils.bzl",
     "get_lib_name",
)

_DefaultCompileInfo = provider(
  doc = "Default compilation files and configuration.",
  fields = {
    "args": "Default argument list.",
    "haddock_args": "Default Haddock argument list.",
    "inputs": "Default inputs.",
    "outputs": "Default outputs.",
    "objects_dir": "Object files directory.",
    "interfaces_dir": "Interface files directory.",
    "object_files": "Object files.",
    "object_dyn_files": "Dynamic object files.",
    "interface_files": "Interface files.",
    "env": "Default env vars."
  },
)

def _hs_srcs(ctx):
  """Return sources that correspond to a Haskell module."""
  # TODO This may be not entirely correct because it does not take into
  # account sources produced by the hsc2hs tool. This probably leads to
  # undeclared object files from those inputs.
  return [f for f in ctx.files.srcs if f.extension in ["hs", "hsc", "lhs"]]

def _mangle_solib(ctx, label, solib, preserve_name):
  """Create a symlink to a dynamic library, with a longer name.

  The built-in cc_* rules don't link against a shared library
  directly. They link against a symlink whose name is guaranteed to be
  unique across the entire workspace. This disambiguates dynamic
  libraries with the same soname. This process is called "mangling".
  The built-in rules don't expose mangling functionality directly (see
  https://github.com/bazelbuild/bazel/issues/4581). But this function
  emulates the built-in dynamic library mangling.

  Args:
    ctx: Rule context.
    label: the label to use as a qualifier for the dynamic library name.
    solib: the dynamic library.
    preserve_name: Bool, whether given `solib` should be returned unchanged.

  Returns:
    File: the created symlink or the original solib.
  """

  if preserve_name:
    return solib

  components = [c for c in [label.workspace_root, label.package, label.name] if c]
  qualifier = '/'.join(components).replace('_', '_U').replace('/', '_S')
  qualsolib = ctx.actions.declare_file("lib" + qualifier + "_" + solib.basename)

  # NOTE We only have relative paths at our disposal here, so we must
  # specify the link target as a path that is relative to the link location.
  # This allows us to avoid the $(realpath ...) hack and makes the resulting
  # directory tree movable (at least in theory).
  relative_solib = paths.relativize(solib.path, qualsolib.dirname)

  ctx.actions.run(
    inputs = [solib],
    outputs = [qualsolib],
    executable = tools(ctx).ln,
    arguments = ["-s", relative_solib, qualsolib.path],
  )
  return qualsolib

def _is_shared_library(f):
  """Check if the given File is a shared library.

  Args:
    f: The File to check.

  Returns:
    Bool: True if the given file `f` is a shared library, False otherwise.
  """
  return f.extension == "so" or f.basename.find(".so.") != -1

def _add_external_libraries(args, libs):
  """Add options to `args` that allow us to link to `libs`.

  Args:
    args: Args object.
    libs: set of external shared libraries.
  """
  seen_libs = set.empty()
  for lib in set.to_list(libs):
    lib_name = get_lib_name(lib)
    if not set.is_member(seen_libs, lib_name):
      set.mutable_insert(seen_libs, lib_name)
      args.add([
        "-l{0}".format(lib_name),
        "-L{0}".format(paths.dirname(lib.path)),
      ])

def _add_mode_options(ctx, args):
  """Add mode options to the given args object.

  Args:
    ctx: Rule context.
    args: args object.

  Returns:
    None
  """
  if is_profiling_enabled(ctx):
    args.add("-prof")

def compile_haskell_bin(ctx):
  """Compile a Haskell target into object files suitable for linking.

  Args:
    ctx: Rule context.

  Returns:
    (list of File, list of File):
      * Object files
      * Dynamic object files
  """
  c = _compilation_defaults(ctx)
  c.args.add(["-main-is", ctx.attr.main_function])

  ctx.actions.run(
    inputs = c.inputs,
    outputs = c.outputs,
    progress_message = "Building {0}".format(ctx.attr.name),
    env = c.env,
    executable = tools(ctx).ghc,
    arguments = [c.args]
  )

  return c.object_files, c.object_dyn_files

def _create_dummy_archive(ctx):
  """Create empty archive so that GHC has some input files to work on during
  linking.

  See: https://github.com/facebook/buck/blob/126d576d5c07ce382e447533b57794ae1a358cc2/src/com/facebook/buck/haskell/HaskellDescriptionUtils.java#L295

  Args:
    ctx: Rule context.

  Returns:
    File, the created dummy archive.
  """

  dummy_raw = "BazelDummy.hs"
  dummy_input = ctx.actions.declare_file(dummy_raw)
  dummy_object = ctx.actions.declare_file(paths.replace_extension(dummy_raw, ".o"))

  ctx.actions.write(output=dummy_input, content="""
{-# LANGUAGE NoImplicitPrelude #-}
module BazelDummy () where
""")

  dummy_static_lib = ctx.actions.declare_file("libempty.a")
  ctx.actions.run(
    inputs = [dummy_input],
    outputs = [dummy_object],
    executable = tools(ctx).ghc,
    arguments = ["-no-link", dummy_input.path],
  )

  ar_args = ctx.actions.args()
  ar_args.add(["qc", dummy_static_lib, dummy_object])

  ctx.actions.run(
    inputs = [dummy_object],
    outputs = [dummy_static_lib],
    executable = tools(ctx).ar,
    arguments = [ar_args]
  )

  return dummy_static_lib

def link_bin(ctx, object_files, so_extension):
  """Link Haskell binary from static object files.

  Args:
    ctx: Rule context.
    TODO
  """

  dummy_static_lib = _create_dummy_archive(ctx)

  args = ctx.actions.args()
  _add_mode_options(ctx, args)
  args.add(ctx.attr.compiler_flags)
  output_exe = ctx.actions.declare_file(
    paths.replace_extension(ctx.attr.name, ".so")
  ) if so_extension else ctx.outputs.executable

  args.add(["-pie", "-o", output_exe.path, dummy_static_lib.path])

  for o in object_files:
    args.add(["-optl", o.path])

  dep_info = gather_dep_info(ctx)

  # De-duplicate optl calls while preserving ordering: we want last
  # invocation of an object to remain last. That is `-optl foo -optl
  # bar -optl foo` becomes `-optl bar -optl foo`. Do this by counting
  # number of occurrences. That way we only build dict and add to args
  # directly rather than doing multiple reversals with temporary
  # lists.
  link_paths = {}

  for lib in dep_info.static_libraries:
    link_paths[lib] = link_paths.get(lib, 0) + 1

  for lib in dep_info.static_libraries:
    occ = link_paths.get(lib, 0)
    # This is the last occurrence of the lib, insert it.
    if occ == 1:
      args.add(["-optl", lib.path])
    link_paths[lib] = occ - 1

  # We have to remember to specify all (transitive) wired-in
  # dependencies or we can't find objects for linking.
  for p in set.to_list(dep_info.prebuilt_dependencies):
    args.add(["-package", p])

  _add_external_libraries(args, dep_info.external_libraries)

  # The resulting test executable should be able to find all external
  # libraries when it is run by Bazel. That is achieved by setting RPATH to
  # a relative path which when joined with working directory points to
  # symlinks which in turn point to shared libraries. This is quite similar
  # to the approach taken by cc_binary, cc_test, etc.:
  #
  # https://github.com/bazelbuild/bazel/blob/f98a7a2fedb3e714cef1038dcb85f83731150246/src/main/java/com/google/devtools/build/lib/rules/cpp/CppActionConfigs.java#L587-L605
  so_symlink_prefix = paths.relativize(
    paths.dirname(output_exe.path),
    ctx.bin_dir.path,
  )
  args.add(["-optl-Wl,-rpath," + so_symlink_prefix])

  ctx.actions.run(
    inputs = depset(transitive = [
      depset(dep_info.static_libraries),
      depset(object_files),
      depset([dummy_static_lib]),
      set.to_depset(dep_info.external_libraries),
    ]),
    outputs = [output_exe],
    progress_message = "Linking {0}".format(output_exe),
    executable = tools(ctx).ghc,
    arguments = [args]
  )

  return output_exe, so_symlink_prefix

def compile_haskell_lib(ctx):
  """Build arguments for Haskell package build.

  Args:
    ctx: Rule context.

  Returns:
    (File, list of File, list of File, list of File):
      Returns in following order:

        * Directory containing interface files
        * Interface files
        * Object files
        * Dynamic object files
        * Haddock args
  """
  c = _compilation_defaults(ctx)
  c.args.add([
    "-package-name", _get_pkg_id(ctx),
  ])

  # This is absolutely required otherwise GHC doesn't know what package it's
  # creating `Name`s for to put them in Haddock interface files which then
  # results in Haddock not being able to find names for linking in
  # environment after reading its interface file later.
  unit_id_args = ["-this-unit-id", _get_pkg_id(ctx)]

  c.args.add(unit_id_args)
  c.haddock_args.add(unit_id_args, before_each="--optghc")

  ctx.actions.run(
    inputs = c.inputs,
    outputs = c.outputs,
    progress_message = "Compiling {0}".format(ctx.attr.name),
    env = c.env,
    executable = tools(ctx).ghc,
    arguments = [c.args],
  )

  return c.interfaces_dir, c.interface_files, c.object_files, c.object_dyn_files, c.haddock_args

def link_static_lib(ctx, object_files):
  """Link a static library for the package using given object files.

  Args:
    ctx: Rule context.
    object_files: All object files to include in the library.

  Returns:
    File: Produced static library.
  """
  static_library = ctx.actions.declare_file("lib{0}.a".format(_get_library_name(ctx)))

  args = ctx.actions.args()
  args.add(["qc", static_library])
  args.add(object_files)

  ctx.actions.run(
    inputs = object_files,
    outputs = [static_library],
    progress_message = "Linking static library {0}".format(static_library.basename),
    executable = tools(ctx).ar,
    arguments = [args],
  )
  return static_library

def link_dynamic_lib(ctx, object_files):
  """Link a dynamic library for the package using given object files.

  Args:
    ctx: Rule context.
    object_files: Object files to use for linking.

  Returns:
    File: Produced dynamic library.
  """

  version = get_ghc_version(ctx)
  dynamic_library = ctx.actions.declare_file(
    "lib{0}-ghc{1}.so".format(_get_library_name(ctx), version)
  )

  args = ctx.actions.args()

  _add_mode_options(ctx, args)

  args.add(["-shared", "-dynamic", "-o", dynamic_library.path])

  dep_info = gather_dep_info(ctx)

  for n in set.to_list(
      set.union(
        dep_info.package_names,
        set.from_list(ctx.attr.prebuilt_dependencies)
      )):
    args.add(["-package", n])

  for c in set.to_list(dep_info.package_caches):
    args.add(["-package-db", c.dirname])

  _add_external_libraries(args, dep_info.external_libraries)

  args.add([ f.path for f in object_files ])

  ctx.actions.run(
    inputs = depset(transitive = [
      depset(object_files),
      set.to_depset(dep_info.package_caches),
      set.to_depset(dep_info.dynamic_libraries),
      set.to_depset(dep_info.external_libraries),
    ]),
    outputs = [dynamic_library],
    progress_message = "Linking dynamic library {0}".format(dynamic_library.basename),
    executable = tools(ctx).ghc,
    arguments = [args]
  )

  return dynamic_library

def create_ghc_package(ctx, interfaces_dir, static_library, dynamic_library):
  """Create GHC package using ghc-pkg.

  Args:
    ctx: Rule context.
    interfaces_dir: Directory containing interface files.
    static_library: Static library of the package.
    dynamic_library: Dynamic library of the package.

  Returns:
    (File, File): GHC package conf file, GHC package cache file
  """
  pkg_db_dir = ctx.actions.declare_directory(_get_pkg_id(ctx))
  conf_file = ctx.actions.declare_file(paths.join(pkg_db_dir.basename, "{0}.conf".format(_get_pkg_id(ctx))))
  cache_file = ctx.actions.declare_file("package.cache", sibling=conf_file)
  dep_info = gather_dep_info(ctx)
  lib_info = infer_lib_info(ctx)

  # Create a file from which ghc-pkg will create the actual package from.
  registration_file = ctx.actions.declare_file(target_unique_name(ctx, "registration-file"))
  registration_file_entries = {
    "name": ctx.attr.name,
    "version": ctx.attr.version,
    "id": _get_pkg_id(ctx),
    "key": _get_pkg_id(ctx),
    "exposed": "True",
    "exposed-modules": " ".join(set.to_list(lib_info.exposed_modules)),
    "hidden-modules": " ".join(set.to_list(lib_info.other_modules)),
    "import-dirs": paths.join("${pkgroot}", interfaces_dir.basename),
    "library-dirs": "${pkgroot}",
    "dynamic-library-dirs": "${pkgroot}",
    "hs-libraries": _get_library_name(ctx),
    "depends":
      ", ".join([ d[HaskellLibraryInfo].package_name for d in ctx.attr.deps if HaskellLibraryInfo in d])
  }
  ctx.actions.write(
    output=registration_file,
    content="\n".join(['{0}: {1}'.format(k, v)
                       for k, v in registration_file_entries.items()])
  )

  # Make the call to ghc-pkg and use the registration file
  package_path = ":".join([c.dirname for c in set.to_list(dep_info.package_confs)])
  ctx.actions.run(
    inputs = depset(transitive = [
      set.to_depset(dep_info.package_confs),
      set.to_depset(dep_info.package_caches),
      depset([static_library, interfaces_dir, registration_file, dynamic_library]),
    ]),
    outputs = [pkg_db_dir, conf_file, cache_file],
    env = {
      "GHC_PACKAGE_PATH": package_path,
    },
    executable = tools(ctx).ghc_pkg,
    arguments = [
      "register", "--package-db={0}".format(pkg_db_dir.path),
      "--no-expand-pkgroot",
      registration_file.path
    ]
  )

  return conf_file, cache_file

def _compilation_defaults(ctx):
  """Declare default compilation targets and create default compiler arguments.

  Args:
    ctx: Rule context.
    for_binary: We're compiling a binary target.

  Returns:
    _DefaultCompileInfo: Populated default compilation settings.
  """
  args = ctx.actions.args()
  haddock_args = ctx.actions.args()

  # Preprocess any sources
  sources = hsc_to_hs(ctx)

  # Declare file directories
  objects_dir_raw = target_unique_name(ctx, "objects")
  objects_dir = ctx.actions.declare_directory(objects_dir_raw)
  interfaces_dir_raw = target_unique_name(ctx, "interfaces")
  interfaces_dir = ctx.actions.declare_directory(interfaces_dir_raw)

  # Compilation mode and explicit user flags
  if ctx.var["COMPILATION_MODE"] == "opt":
    args.add("-O2")

  args.add(ctx.attr.compiler_flags)
  haddock_args.add(ctx.attr.compiler_flags, before_each="--optghc")

  # Output static and dynamic object files.
  args.add(["-static", "-dynamic-too"])

  # Common flags
  args.add([
    "-c",
    "--make",
    "-fPIC",
    "-hide-all-packages",
  ])
  haddock_args.add(["-hide-all-packages"], before_each="--optghc")

  args.add([
    "-odir", objects_dir,
    "-hidir", interfaces_dir,
  ])

  _add_mode_options(ctx, args)

  dep_info = gather_dep_info(ctx)

  # Add import hierarchy root.
  ih_root_arg = ["-i{0}".format(import_hierarchy_root(ctx))]
  args.add(ih_root_arg)
  haddock_args.add(ih_root_arg, before_each="--optghc")

  # Expose all prebuilt dependencies
  for prebuilt_dep in ctx.attr.prebuilt_dependencies:
    items = ["-package", prebuilt_dep]
    args.add(items)
    haddock_args.add(items, before_each="--optghc")

  # Expose all bazel dependencies
  for package in set.to_list(dep_info.package_names):
    items = ["-package", package]
    args.add(items)
    if package != _get_pkg_id(ctx):
      haddock_args.add(items, before_each="--optghc")

  # Only include package DBs for deps, prebuilt deps should be found
  # auto-magically by GHC.
  for cache in set.to_list(dep_info.package_caches):
    items = ["-package-db", cache.dirname]
    args.add(items)
    haddock_args.add(items, before_each="--optghc")

  # We want object and dynamic objects from all inputs.
  object_files = []
  object_dyn_files = []

  # We need to keep interface files we produce so we can import
  # modules cross-package.
  interface_files = []

  textual_headers = []

  # Output object files are named after modules, not after input file names.
  # The difference is only visible in the case of Main module because it may
  # be placed in a file with a name different from "Main.hs". In that case
  # still Main.o will be produced.

  for s in _hs_srcs(ctx):

    if s.extension == "h":
      textual_headers.append(s)
    elif not hasattr(ctx.file, "main_file") or (s != ctx.file.main_file):
      object_files.append(
        declare_compiled(ctx, s, ".o", directory=objects_dir)
      )
      object_dyn_files.append(
        declare_compiled(ctx, s, ".dyn_o", directory=objects_dir)
      )
      interface_files.append(
        declare_compiled(ctx, s, ".hi", directory=interfaces_dir)
      )
    else:
      object_files.append(
        ctx.actions.declare_file(paths.join(objects_dir_raw, "Main.o"))
      )
      object_files.append(
        ctx.actions.declare_file(paths.join(objects_dir_raw, "Main.dyn_o"))
      )
      interface_files.append(
        ctx.actions.declare_file(paths.join(interfaces_dir_raw, "Main.hi"))
      )

  hdrs, include_args = cc_headers(ctx)
  args.add(include_args)
  haddock_args.add(include_args, before_each="--optghc")

  # Lastly add all the processed sources.
  for f in sources:
    if f.extension not in ["hs-boot", "lhs-boot"]:
      args.add(f)
      haddock_args.add(f)

  # Add any interop info for other languages.
  java = java_interop_info(ctx)

  return _DefaultCompileInfo(
    args = args,
    haddock_args = haddock_args,
    inputs = depset(transitive = [
      depset(sources),
      depset(hdrs),
      set.to_depset(dep_info.package_confs),
      set.to_depset(dep_info.package_caches),
      set.to_depset(dep_info.interface_files),
      set.to_depset(dep_info.dynamic_libraries),
      set.to_depset(dep_info.external_libraries),
      java.inputs,
      depset(textual_headers),
      depset([tools(ctx).gcc]),
    ]),
    outputs = [objects_dir, interfaces_dir] + object_files + object_dyn_files + interface_files,
    objects_dir = objects_dir,
    interfaces_dir = interfaces_dir,
    object_files = object_files,
    object_dyn_files = object_dyn_files,
    interface_files = interface_files,
    env = dicts.add({
      "LD_LIBRARY_PATH": get_external_libs_path(dep_info.external_libraries),
      },
      java.env,
    ),
  )

def _get_pkg_id(ctx):
  """Get package identifier. This is name-version.

  Args:
    ctx: Rule context

  Returns:
    string: GHC package ID to use.
  """
  return "{0}-{1}".format(ctx.attr.name, ctx.attr.version)

def _get_library_name(ctx):
  """Get core library name for this package. This is "HS" followed by package ID.

  See https://ghc.haskell.org/trac/ghc/ticket/9625 .

  Args:
    ctx: Rule context.

  Returns:
    string: Library name suitable for GHC package entry.
  """
  return "HS{0}".format(_get_pkg_id(ctx))

def gather_dep_info(ctx):
  """Collapse dependencies into a single `HaskellBuildInfo`.

  Note that the field `prebuilt_dependencies` also includes
  prebuilt_dependencies of current target.

  Args:
    ctx: Rule context.

  Returns:
    HaskellBuildInfo: Unified information about all dependencies.
  """

  acc = HaskellBuildInfo(
    package_names = set.empty(),
    package_confs = set.empty(),
    package_caches = set.empty(),
    static_libraries = [],
    dynamic_libraries = set.empty(),
    interface_files = set.empty(),
    prebuilt_dependencies = set.from_list(ctx.attr.prebuilt_dependencies),
    external_libraries = set.empty(),
  )

  for dep in ctx.attr.deps:
    if HaskellBuildInfo in dep:
      binfo = dep[HaskellBuildInfo]
      package_names = acc.package_names
      if HaskellBinaryInfo in dep:
        fail("Target {0} cannot depend on binary".format(ctx.attr.name))
      if HaskellLibraryInfo in dep:
        set.mutable_insert(package_names, dep[HaskellLibraryInfo].package_name)
      acc = HaskellBuildInfo(
        package_names = package_names,
        package_confs = set.mutable_union(acc.package_confs, binfo.package_confs),
        package_caches = set.mutable_union(acc.package_caches, binfo.package_caches),
        static_libraries = acc.static_libraries + binfo.static_libraries,
        dynamic_libraries = set.mutable_union(acc.dynamic_libraries, binfo.dynamic_libraries),
        interface_files = set.mutable_union(acc.interface_files, binfo.interface_files),
        prebuilt_dependencies = set.mutable_union(acc.prebuilt_dependencies, binfo.prebuilt_dependencies),
        external_libraries = set.mutable_union(acc.external_libraries, binfo.external_libraries),
      )
    else:
      # If not a Haskell dependency, pass it through as-is to the
      # linking phase.
      acc = HaskellBuildInfo(
        package_names = acc.package_names,
        package_confs = acc.package_confs,
        package_caches = acc.package_caches,
        static_libraries = acc.static_libraries,
        dynamic_libraries = acc.dynamic_libraries,
        interface_files = acc.interface_files,
        prebuilt_dependencies = acc.prebuilt_dependencies,
        external_libraries = set.mutable_union(
          acc.external_libraries,
          set.from_list([
            # If the provider is CcSkylarkApiProviderHacked, then the .so
            # files come from haskell_cc_import.
            _mangle_solib(ctx, dep.label, f, CcSkylarkApiProviderHacked in dep)
            for f in dep.files.to_list() if _is_shared_library(f)
          ]),
        ),
      )

  return acc

def infer_lib_info(ctx, haddock_args=[]):
  """Return populated `HaskellLibraryInfo` provider.

  Args:
    ctx: Rule context.
    haddock_args: Value to use in corresponding field.

  Returns:
    HaskellLibraryInfo: library-specific information.
  """

  # Infer collection of public modules in the library.
  exposed_modules = set.empty()
  other_modules = set.from_list(ctx.attr.hidden_modules) if hasattr(ctx.attr, "hidden_modules") else set.empty()

  for f in _hs_srcs(ctx):
    mname = module_name(ctx, f)
    if not set.is_member(other_modules, mname):
      set.mutable_insert(exposed_modules, mname)

  return HaskellLibraryInfo(
    package_name = _get_pkg_id(ctx),
    import_dir = import_hierarchy_root(ctx),
    exposed_modules = exposed_modules,
    other_modules = other_modules,
    haddock_args = haddock_args
  )

def infer_bin_info(ctx, dynamic_bin):
  """Return populated `HaskellBinaryInfo` provider.

  Args:
    ctx: Rule context.
    dynamic_bin: File, binary compiled from dynamic object files.

  Returns:
    HaskellBinaryInfo: binary-specific information.
  """

  modules = []

  for f in _hs_srcs(ctx):
    if f == ctx.file.main_file:
      modules.append("Main")
    else:
      modules.append(module_name(ctx, f))

  return HaskellBinaryInfo(
    source_files = set.from_list(ctx.files.srcs),
    modules = set.from_list(modules),
    dynamic_bin = dynamic_bin,
  )
