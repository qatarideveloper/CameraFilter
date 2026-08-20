export THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = Photos

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CameraFilter

CameraFilter_FILES = Tweak.x
CameraFilter_CFLAGS = -fobjc-arc
CameraFilter_FRAMEWORKS = UIKit Photos ImageIO CoreGraphics

include $(THEOS)/makefiles/tweak.mk
