# naples: a Dock for GNUstep + Window Maker (Darwin/XNU) -- see README.md.
include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = Naples
VERSION = 0.3
Naples_OBJC_FILES = main.m NaplesX.m NaplesDock.m NaplesDockView.m NaplesBar.m NaplesBarView.m NaplesPanel.m
Naples_MAIN_MODEL_FILE =
Naples_APPLICATION_ICON = Naples.tiff
Naples_RESOURCE_FILES = icons/hexley_head.png icons/Naples.tiff icons/Naples.png
Naples_LOCALIZED_RESOURCE_FILES =

ADDITIONAL_OBJCFLAGS += -O2 -Wall -fblocks

include $(GNUSTEP_MAKEFILES)/application.make
