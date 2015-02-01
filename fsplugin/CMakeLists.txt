CMAKE_MINIMUM_REQUIRED(VERSION 2.8.11)

PROJECT(seafile-fsplugin)
SET(PROJECT_VERSION "1.0.0")

IF (NOT (${CMAKE_BUILD_TYPE} MATCHES Release))
  SET(CMAKE_BUILD_TYPE Debug)
ENDIF()

SET(CODESIGN_CERTIFICATE "-" CACHE STRING "the certificate to sign code")

MESSAGE(STATUS "Build type: ${CMAKE_BUILD_TYPE}")

IF (NOT APPLE)
    MESSAGE(FATAL_ERROR "Support only on OS X")
ENDIF()

IF (NOT CMAKE_GENERATOR STREQUAL Xcode)
    MESSAGE(FATAL_ERROR "Support only for Xcode generator")
ENDIF()

FIND_LIBRARY(AppKit_LIBRARY AppKit)
FIND_LIBRARY(FinderSync_LIBRARY FinderSync)

FIND_LIBRARY(PlugInKit_LIBRARY PlugInKit
  PATHS /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.10.sdk/System/Library/PrivateFrameworks/)

if (NOT PlugInKit_LIBRARY)
  MESSAGE(FATAL_ERROR "PlugInKit not found")
endif()

ADD_DEFINITIONS(-fapplication-extension -fmodules)
SET(CMAKE_EXE_LINKER_FLAGS "-fapplication-extension -e _NSExtensionMain -fobjc-arc -fobjc-link-runtime ${CMAKE_EXE_LINKER_FLAGS}")

INCLUDE_DIRECTORIES(${CMAKE_CURRENT_SOURCE_DIR})
ADD_EXECUTABLE(seafile-finder-sync MACOSX_BUNDLE
  FinderSync.mm
  FinderSyncClient.mm
)

SET_TARGET_PROPERTIES(seafile-finder-sync PROPERTIES
  OUTPUT_NAME "Seafile FinderSync"
  MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist
  XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET "10.10"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES"
  XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "gnu++11"
  XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY "libc++"
  )

TARGET_LINK_LIBRARIES(seafile-finder-sync
  ${FinderSync_LIBRARY}
  ${PlugInKit_LIBRARY}
  ${AppKit_LIBRARY}
)

FIND_PROGRAM(CODESIGN codesign)

SET(BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}/\${CONFIGURATION}/Seafile FinderSync.app")
SET(TARGET_DIR "${CMAKE_CURRENT_BINARY_DIR}/Seafile FinderSync.appex")
ADD_CUSTOM_COMMAND(TARGET seafile-finder-sync
  POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E remove -f ${TARGET_DIR} &&
  ${CMAKE_COMMAND} -E copy_directory ${BUILD_DIR} ${TARGET_DIR} &&
  ${CODESIGN} --force --sign ${CODESIGN_CERTIFICATE} --entitlements ${CMAKE_CURRENT_SOURCE_DIR}/seafile-fsplugin.entitlements ${TARGET_DIR}
  )
