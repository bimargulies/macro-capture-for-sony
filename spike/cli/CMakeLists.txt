cmake_minimum_required(VERSION 3.10)
project(LiveViewProbe LANGUAGES CXX)

set(SDK_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/CrSDK_v2.02.00_20260610a_Mac/unpacked/SimpleCli"
    CACHE PATH "SimpleCli dir containing app/CRSDK and external/crsdk")
set(HDR_DIR ${SDK_ROOT}/app/CRSDK)
set(LIB_DIR ${SDK_ROOT}/external/crsdk)

set(CMAKE_OSX_DEPLOYMENT_TARGET "12.1" CACHE STRING "")
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "")

add_executable(focusprobe focusprobe.cpp ${SDK_ROOT}/app/CrDebugString.cpp)
target_include_directories(focusprobe PRIVATE ${HDR_DIR} ${SDK_ROOT}/app)
find_library(CR_CORE Cr_Core HINTS ${LIB_DIR} NO_DEFAULT_PATH REQUIRED)
target_link_libraries(focusprobe PRIVATE ${CR_CORE})
set_target_properties(focusprobe PROPERTIES
    CXX_STANDARD 17 CXX_STANDARD_REQUIRED YES CXX_EXTENSIONS NO
    BUILD_RPATH "@executable_path")

# The SDK expects its adapter dylibs in Contents/Frameworks/CrAdapter next to the exe.
add_custom_command(TARGET focusprobe POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${LIB_DIR} $<TARGET_FILE_DIR:focusprobe>
    COMMAND ${CMAKE_COMMAND} -E make_directory $<TARGET_FILE_DIR:focusprobe>/Contents/Frameworks/CrAdapter
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${LIB_DIR}/CrAdapter $<TARGET_FILE_DIR:focusprobe>/Contents/Frameworks/CrAdapter
)
