cmake_minimum_required(VERSION 3.23)
project(Greetings LANGUAGES CXX)

# Export the sample functions from the DLLs with the MSVC toolchain.
set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
include(GNUInstallDirs)

if(APPLE)
  set(CMAKE_INSTALL_RPATH "@loader_path;@loader_path/../${CMAKE_INSTALL_LIBDIR}")
elseif(UNIX)
  set(CMAKE_INSTALL_RPATH "$ORIGIN;$ORIGIN/../${CMAKE_INSTALL_LIBDIR}")
endif()

add_library(base SHARED src/base.cpp)
target_include_directories(base PUBLIC include)
target_compile_definitions(base PRIVATE GREETING_BASE_VALUE=21)

add_library(extended SHARED src/extended.cpp)
target_link_libraries(extended PUBLIC base)

add_executable(hello_base src/hello_base.cpp)
target_link_libraries(hello_base PRIVATE base)
add_executable(hello_extended src/hello_extended.cpp)
target_link_libraries(hello_extended PRIVATE extended)

install(TARGETS base extended hello_base hello_extended)
install(DIRECTORY include/ DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
