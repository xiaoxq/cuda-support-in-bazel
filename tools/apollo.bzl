# This file is adapted from tensorflow.git/tensorflow/tensorflow.bzl

load("//tools/platform:rules_cc.bzl", "cc_binary", "cc_library", "cc_test")
#load("@local_config_tensorrt//:build_defs.bzl", "if_tensorrt")

load("//tools/platform:cuda_build_defs.bzl", "if_cuda_is_configured")
load(
    "@local_config_cuda//cuda:build_defs.bzl",
    "cuda_library",
    "if_cuda",
)

# placeholder for mkl, Intel Math Kernel Library

# Sanitize a dependency so that it works correctly from code that includes
# Apollo as a submodule.
def clean_dep(dep):
    return str(Label(dep))

def if_nvcc(a):
    return select({
        "@local_config_cuda//cuda:using_nvcc": a,
        "//conditions:default": [],
    })

def if_cuda_is_configured_compat(x):
    return if_cuda_is_configured(x)

# Given a source file, generate a test name.
# i.e. "common_runtime/direct_session_test.cc" becomes
#      "common_runtime_direct_session_test"
def src_to_test_name(src):
    return src.replace("/", "_").replace(":", "_").split(".")[0]

def full_path(relative_paths):
    return [native.package_name() + "/" + relative for relative in relative_paths]

def if_x86_mode(a):
    return select({
        clean_dep("//tools/platform:x86_mode"): a,
        "//conditions:default": [],
    })

# Linux systems may required -lrt linker flag for e.g. clock_gettime
# see https://github.com/tensorflow/tensorflow/issues/15129
def lrt_if_needed():
    lrt = ["-lrt"]
    return select({
        clean_dep("//tools/platform:aarch64_mode"): lrt,
        clean_dep("//tools/platform:x86_mode"): lrt,
        "//conditions:default": [],
    })

#def apollo_opts_nortti():
#return [
#    "-fno-rtti",
#    "-DGOOGLE_PROTOBUF_NO_RTTI",
#    "-DGOOGLE_PROTOBUF_NO_STATIC_INITIALIZER",
#]
#def apollo_defines_nortti():
#    return [
#        "GOOGLE_PROTOBUF_NO_RTTI",
#        "GOOGLE_PROTOBUF_NO_STATIC_INITIALIZER",
#    ]

# if_tensorrt(["-DGOOGLE_TENSORRT=1"]) +
def apollo_copts(allow_exceptions = False):
    return (
        [
            "-DEIGEN_AVOID_STL_ARRAY",
            "-Wno-sign-compare",
            "-ftemplate-depth=900",
        ] + if_cuda(["-DGOOGLE_CUDA=1"]) +
        if_nvcc(["-DAPOLLO_USE_NVCC=1"]) +
        if_x86_mode(["-msse3"]) +
        (["-fno-exceptions"] if not allow_exceptions else []) +
        ["-pthread"]
    )

def apollo_gpu_library(deps = None, cuda_deps = None, copts = apollo_copts(), **kwargs):
    """Generate a cc_library with a conditional set of CUDA dependencies.

      When the library is built with --config=cuda:

      - Both deps and cuda_deps are used as dependencies.
      - The cuda runtime is added as a dependency (if necessary).
      - The library additionally passes -DGOOGLE_CUDA=1 to the list of copts.
      - In addition, when the library is also built with TensorRT enabled, it
          additionally passes -DGOOGLE_TENSORRT=1 to the list of copts.

      Args:
      - cuda_deps: BUILD dependencies which will be linked if and only if:
          '--config=cuda' is passed to the bazel command line.
      - deps: dependencies which will always be linked.
      - copts: copts always passed to the cc_library.
      - kwargs: Any other argument to cc_library.
      """
    if not deps:
        deps = []
    if not cuda_deps:
        cuda_deps = []

    kwargs["features"] = kwargs.get("features", []) + ["-use_header_modules"]
    cc_library(
        deps = deps + if_cuda_is_configured_compat(cuda_deps + [
            "@local_config_cuda//cuda:cuda_headers",
        ]),
        copts = (copts + if_cuda(["-DGOOGLE_CUDA=1"])),
        #if_tensorrt(["-DGOOGLE_TENSORRT=1"])),
        **kwargs
    )

# terminology interoperability: saving apollo_cuda_* definition for convenience
def apollo_cuda_library(*args, **kwargs):
    apollo_gpu_library(*args, **kwargs)

def _cuda_copts(opts = []):
    """Gets the appropriate set of copts for (maybe) CUDA compilation.

        If we're doing CUDA compilation, returns copts for our particular CUDA
        compiler.  If we're not doing CUDA compilation, returns an empty list.

        """
    return select({
        "//conditions:default": [],
        "@local_config_cuda//cuda:using_nvcc": ([
            "-nvcc_options=relaxed-constexpr",
            "-nvcc_options=ftz=true",
        ]),
        "@local_config_cuda//cuda:using_clang": ([
            "-fcuda-flush-denormals-to-zero",
        ]),
    }) + if_cuda_is_configured_compat(opts)

def apollo_gpu_kernel_library(
        srcs,
        copts = [],
        cuda_copts = [],
        deps = [],
        hdrs = [],
        **kwargs):
    copts = copts + apollo_copts() + _cuda_copts(opts = cuda_copts)
    kwargs["features"] = kwargs.get("features", []) + ["-use_header_modules"]

    cuda_library(
        srcs = srcs,
        hdrs = hdrs,
        copts = copts,
        deps = deps,
        alwayslink = 1,
        **kwargs
    )

def if_override_eigen_strong_inline(a):
    return select({
        clean_dep("//tools/platform:override_eigen_strong_inline"): a,
        "//conditions:default": [],
    })

def _make_search_paths(prefix, levels_to_root):
    return ",".join(
        [
            "-rpath,%s/%s" % (prefix, "/".join([".."] * search_level))
            for search_level in range(levels_to_root + 1)
        ],
    )

def _rpath_linkopts(name):
    # Search parent directories up to the Apollo root directory for shared
    # object dependencies, even if this shared object is deeply nested
    levels_to_root = native.package_name().count("/") + name.count("/")
    return ["-Wl,%s" % (_make_search_paths("$$ORIGIN", levels_to_root))]

# TODO(pcloudy): Remove this workaround when https://github.com/bazelbuild/bazel/issues/4570
# is done and cc_shared_library is available.
# On Linux, shared libraries are usually named as libfoo.so
LINUX_SHARED_LIBRARY_NAME_PATTERN = "lib%s.so%s"

def apollo_cc_shared_object(
        name,
        srcs = [],
        deps = [],
        data = [],
        linkopts = lrt_if_needed(),
        soversion = None,
        kernels = [],
        visibility = None,
        **kwargs):
    """Configure the shared object (.so) file for Apollo."""
    if soversion != None:
        suffix = "." + str(soversion).split(".")[0]
        longsuffix = "." + str(soversion)
    else:
        suffix = ""
        longsuffix = ""

    #linux_pattern = LINUX_SHARED_LIBRARY_NAME_PATTERN
    #name_on_linux = (
    #    linux_pattern % (name, ""),
    #    linux_pattern % (name, suffix),
    #    linux_pattern % (name, longsuffix),
    #)
    name_on_linux = (name, name + suffix, name + longsuffix)
    (name_os, name_os_major, name_os_full) = name_on_linux
    if name_os != name_os_major:
        native.genrule(
            name = name_os + "_sym",
            outs = [name_os],
            srcs = [name_os_major],
            output_to_bindir = 1,
            cmd = "ln -sf $$(basename $<) $@",
        )
        native.genrule(
            name = name_os_major + "_sym",
            outs = [name_os_major],
            srcs = [name_os_full],
            output_to_bindir = 1,
            cmd = "ln -sf $$(basename $<) $@",
        )

    soname = name_os_major.split("/")[-1]

    cc_binary(
        name = name_os_full,
        srcs = srcs,
        deps = deps,
        linkshared = 1,
        data = data,
        linkopts = linkopts + _rpath_linkopts(name_os_full) + [
            "-Wl,-soname," + soname,
        ],
        visibility = visibility,
        **kwargs
    )

    flattened_names = list(name_on_linux)
    if name not in flattened_names:
        native.filegroup(
            name = name,
            srcs = [":lib%s.so%s" % (name, longsuffix)],
            visibility = visibility,
        )

def apollo_kernel_library(
        name,
        prefix = None,
        srcs = None,
        gpu_srcs = None,
        hdrs = None,
        deps = None,
        alwayslink = 1,
        copts = None,
        gpu_copts = None,
        **kwargs):
    """A rule to build CUDA Kernel.

      May either specify srcs/hdrs or prefix.  Similar to apollo_gpu_library,
      but with alwayslink=1 by default.  If prefix is specified:
        * prefix*.cc (except *.cu.cc) is added to srcs
        * prefix*.h (except *.cu.h) is added to hdrs
        * prefix*.cu.cc and prefix*.h (including *.cu.h) are added to gpu_srcs.
      With the exception that test files are excluded.
      For example, with prefix = "cast_op",
        * srcs = ["cast_op.cc"]
        * hdrs = ["cast_op.h"]
        * gpu_srcs = ["cast_op_gpu.cu.cc", "cast_op.h"]
        * "cast_op_test.cc" is excluded
      With prefix = "cwise_op"
        * srcs = ["cwise_op_abs.cc", ..., "cwise_op_tanh.cc"],
        * hdrs = ["cwise_ops.h", "cwise_ops_common.h"],
        * gpu_srcs = ["cwise_op_gpu_abs.cu.cc", ..., "cwise_op_gpu_tanh.cu.cc",
                      "cwise_ops.h", "cwise_ops_common.h",
                      "cwise_ops_gpu_common.cu.h"]
        * "cwise_ops_test.cc" is excluded
      """
    if not srcs:
        srcs = []
    if not hdrs:
        hdrs = []
    if not deps:
        deps = []
    if not copts:
        copts = []
    if not gpu_copts:
        gpu_copts = []
    textual_hdrs = []
    copts = copts + apollo_copts()

    # Override EIGEN_STRONG_INLINE to inline when
    # --define=override_eigen_strong_inline=true to avoid long compiling time.
    # See https://github.com/tensorflow/tensorflow/issues/10521
    copts = copts + if_override_eigen_strong_inline(["/DEIGEN_STRONG_INLINE=inline"])
    if prefix:
        if native.glob([prefix + "*.cu.cc"], exclude = ["*test*"]):
            if not gpu_srcs:
                gpu_srcs = []
            gpu_srcs = gpu_srcs + native.glob(
                [prefix + "*.cu.cc", prefix + "*.h"],
                exclude = [prefix + "*test*"],
            )
        srcs = srcs + native.glob(
            [prefix + "*.cc"],
            exclude = [prefix + "*test*", prefix + "*.cu.cc"],
        )
        hdrs = hdrs + native.glob(
            [prefix + "*.h"],
            exclude = [prefix + "*test*", prefix + "*.cu.h", prefix + "*impl.h"],
        )
        textual_hdrs = native.glob(
            [prefix + "*impl.h"],
            exclude = [prefix + "*test*", prefix + "*.cu.h"],
        )
    cuda_deps = []  #clean_dep("//tensorflow/core:gpu_lib")]
    if gpu_srcs:
        for gpu_src in gpu_srcs:
            if gpu_src.endswith(".cc") and not gpu_src.endswith(".cu.cc"):
                fail("{} not allowed in gpu_srcs. .cc sources must end with .cu.cc"
                    .format(gpu_src))
        apollo_gpu_kernel_library(
            name = name + "_gpu",
            srcs = gpu_srcs,
            deps = deps,
            copts = gpu_copts,
            **kwargs
        )
        cuda_deps.extend([":" + name + "_gpu"])

    apollo_gpu_library(
        name = name,
        srcs = srcs,
        hdrs = hdrs,
        textual_hdrs = textual_hdrs,
        copts = copts,
        cuda_deps = cuda_deps,
        linkstatic = 1,  # Needed since alwayslink is broken in bazel b/27630669
        alwayslink = alwayslink,
        deps = deps,
        **kwargs
    )

    # TODO(gunan): CUDA dependency not clear here. Fix it.
    apollo_cc_shared_object(
        name = "liback_%s.so" % name,
        srcs = srcs + hdrs,
        copts = copts,
        deps = deps,
    )
