# Builds the iPad app as a rootful jailbreak .deb with theos and the stock
# Command Line Tools (no Xcode). scripts/bootstrap.sh fetches the toolchain
# into .local/; set THEOS to use an existing install instead.
THEOS ?= $(CURDIR)/.local/theos
export PATH := $(CURDIR)/.local/bin:$(PATH)

TARGET := iphone:clang:14.5:12.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = LegacyDisplay

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = LegacyDisplay
LegacyDisplay_FILES = $(wildcard Sources/*.m)
LegacyDisplay_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics CoreMedia AVFoundation Network
LegacyDisplay_CFLAGS = -fobjc-arc -Wall -Wno-unused-parameter
# Some Command Line Tools installs ship two module maps that both define
# SwiftBridging, which breaks every implicit Clang module build. Plain
# #imports sidestep it and cost nothing at this size.
LegacyDisplay_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/application.mk
