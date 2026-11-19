cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "hotkey_manager_linux")
project(${PROJECT_NAME} LANGUAGES CXX)

# The name the generated plugin list links against; it must not change.
set(PLUGIN_NAME "hotkey_manager_linux_plugin")

add_library(${PLUGIN_NAME} SHARED
  "hotkey_manager_linux_plugin.cc"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

pkg_check_modules(X11 REQUIRED IMPORTED_TARGET x11)
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter PkgConfig::GTK PkgConfig::X11)

set(hotkey_manager_linux_bundled_libraries
  ""
  PARENT_SCOPE
)
