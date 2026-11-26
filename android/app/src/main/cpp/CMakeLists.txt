cmake_minimum_required(VERSION 3.22.1)
project(sito_lzfse C)

# Apple-maintained, permissively licensed LZFSE implementation, pinned as a
# git submodule so Android can read existing encrypted iOS backup chunks.
add_library(lzfse_core STATIC
    lzfse/src/lzfse_decode.c
    lzfse/src/lzfse_decode_base.c
    lzfse/src/lzfse_encode.c
    lzfse/src/lzfse_encode_base.c
    lzfse/src/lzfse_fse.c
    lzfse/src/lzvn_decode_base.c
    lzfse/src/lzvn_encode_base.c
)
target_include_directories(lzfse_core PUBLIC lzfse/src)
set_target_properties(lzfse_core PROPERTIES C_STANDARD 99 POSITION_INDEPENDENT_CODE ON)

add_library(sito_lzfse SHARED lzfse_jni.c)
target_link_libraries(sito_lzfse PRIVATE lzfse_core)
